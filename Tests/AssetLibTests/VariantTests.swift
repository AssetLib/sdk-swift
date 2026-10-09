import Foundation
import CryptoKit
import Testing
@testable import AssetLib

private func variantFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
}
private let variantCoast = AssetReference(key: "travel.coast", width: 1200, height: 900)
private let coastID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let ridgeID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

private actor VariantTransport: AssetTransport {
    private var manifest: Data
    private var objects: [String: Data]
    private(set) var requests: [String] = []
    init(manifest: Data, objects: [String: Data]) { self.manifest = manifest; self.objects = objects }
    func update(manifest: Data, objects: [String: Data]) { self.manifest = manifest; self.objects = objects }
    func resetRequests() { requests = [] }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        requests.append(url.path)
        let data = url.path.hasSuffix("/manifest") ? manifest : objects[url.path]
        guard let data, data.count <= maximumBytes else { throw AssetLibError.invalid("Fixture unavailable") }
        return data
    }
}

private actor Decisions {
    struct Call: Equatable { let key: String; let arms: [String] }
    private(set) var calls: [Call] = []
    var answer: String?
    init(_ answer: String?) { self.answer = answer }
    func decide(_ key: String, _ arms: [String]) -> String? {
        calls.append(.init(key: key, arms: arms))
        return answer
    }
    func reset() { calls = [] }
}

private actor GatedDecision {
    private var called = false
    private var observer: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<String?, Never>?
    func decide() async -> String? {
        called = true
        observer?.resume(); observer = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitUntilCalled() async {
        guard !called else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(returning: "b"); pending = nil }
}

private func variantObjects(_ configuration: AssetConfiguration) throws -> [String: Data] {
    let base = "/api/delivery/\(configuration.orgId)/\(configuration.appId)/assets/"
    return [base + coastID: try variantFixture("assets/coast.webp"), base + ridgeID: try variantFixture("assets/ridge.webp")]
}

private struct SignedVariants {
    // TEST ONLY. Synthetic manifests use their own deterministic private key.
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
    let configuration: AssetConfiguration
    let original: [String: Any]
    init() throws {
        var config = try JSONSerialization.jsonObject(with: variantFixture("config.json")) as! [String: Any]
        let prefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00])
        config["pinnedPublicKey"] = "-----BEGIN PUBLIC KEY-----\n" + (prefix + key.publicKey.rawRepresentation).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
        config.removeValue(forKey: "keyId")
        configuration = try .parse(JSONSerialization.data(withJSONObject: config))
        let envelope = try JSONDecoder().decode(SignedManifest.self, from: variantFixture("manifests/valid-cells-arm-appearance-seq6.json"))
        original = try JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as! [String: Any]
    }
    var slot: [String: Any] { (original["slots"] as! [[String: Any]])[0] }
    var cells: [[String: Any]] { slot["cells"] as! [[String: Any]] }
    func payload(sequence: Int = 6, slot: [String: Any]? = nil) -> [String: Any] {
        var payload = original
        payload["sequence"] = sequence
        payload["slots"] = [slot ?? self.slot]
        return payload
    }
    func envelope(_ payload: [String: Any]) throws -> SignedManifest {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        return SignedManifest(algorithm: "Ed25519", keyId: configuration.signingKeyID,
            publicKey: configuration.pinnedPublicKey, payload: text, signature: try key.signature(for: Data(text.utf8)).base64EncodedString())
    }
    func manifest(_ payload: [String: Any]? = nil) throws -> Data { try JSONEncoder().encode(envelope(payload ?? original)) }
}

@Suite struct VariantTests {
    @Test func everySharedResolutionExpectation() async throws {
        struct Matrix: Decodable {
            struct Entry: Decodable {
                struct Request: Decodable, Sendable { let arm: String?; let appearance: AssetAppearance?; let decision: String? }
                struct Expected: Decodable { let assetId: String; let arm: String?; let appearance: AssetAppearance?; let armSource: String }
                let manifest: String
                let request: Request
                let expect: Expected
            }
            let config: String
            let resolution: [Entry]
        }
        let matrix = try JSONDecoder().decode(Matrix.self, from: variantFixture("cases.json"))
        let configuration = try AssetConfiguration.parse(variantFixture(matrix.config))
        for (index, entry) in matrix.resolution.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = VariantTransport(manifest: try variantFixture(entry.manifest), objects: try variantObjects(configuration))
            let answer = entry.request.decision
            let decide: (@Sendable (String, [String]) async -> String?)?
            if let answer { decide = { @Sendable _, _ in answer } } else { decide = nil }
            let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport, decide: decide)
            #expect(await client.refresh().error == nil)
            let result = await client.resolve(variantCoast, appearance: entry.request.appearance, arm: entry.request.arm)
            #expect(result.source == .remote, "Resolution case \(index)")
            #expect(result.assetID == entry.expect.assetId, "Resolution case \(index)")
            #expect(result.arm == entry.expect.arm, "Resolution case \(index)")
            #expect(result.appearance == entry.expect.appearance, "Resolution case \(index)")
            #expect(result.armSource.rawValue == entry.expect.armSource, "Resolution case \(index)")
        }
    }

    @Test func stagingScopePathsAndStorageIsolation() async throws {
        let production = try AssetConfiguration.parse(variantFixture("config.json"))
        let staging = try AssetConfiguration.parse(variantFixture("config-staging.json"))
        #expect(staging.environment == "staging" && staging.storageNamespace != production.storageNamespace)
        var object = try JSONSerialization.jsonObject(with: variantFixture("config.json")) as! [String: Any]
        let base = "https://fixtures.assetlib.example/api/delivery/\(production.orgId)/\(production.appId)"
        for (environment, suffix) in [("production", "/manifest"), ("production", "/environments/production/manifest"), ("staging", "/environments/staging/manifest")] {
            object["environment"] = environment; object["manifestUrl"] = base + suffix
            #expect(throws: Never.self) { _ = try AssetConfiguration.parse(JSONSerialization.data(withJSONObject: object)) }
        }
        for (environment, suffix) in [("staging", "/manifest"), ("staging", "/environments/production/manifest"), ("production", "/environments/staging/manifest"), ("preview", "/environments/preview/manifest"), ("production", "/environments/Production/manifest"), ("staging", "/environments/staging/manifest/"), ("staging", "/environments/%73taging/manifest")] {
            object["environment"] = environment; object["manifestUrl"] = base + suffix
            #expect(throws: AssetLibError.self) { _ = try AssetConfiguration.parse(JSONSerialization.data(withJSONObject: object)) }
        }
        let stagingEnvelope = try JSONDecoder().decode(SignedManifest.self, from: variantFixture("manifests/valid-staging-seq1.json"))
        let productionEnvelope = try JSONDecoder().decode(SignedManifest.self, from: variantFixture("manifests/valid-seq1.json"))
        #expect(throws: AssetLibError.self) { _ = try ManifestVerifier.verify(stagingEnvelope, config: production) }
        #expect(throws: AssetLibError.self) { _ = try ManifestVerifier.verify(productionEnvelope, config: staging) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = VariantTransport(manifest: try variantFixture("manifests/valid-staging-seq1.json"), objects: try variantObjects(staging))
        let client = try AssetClient(configuration: staging, storage: FileAssetStorage(configuration: staging, root: root), transport: transport)
        #expect(await client.refresh().sequence == 1)
        #expect(await client.resolve(variantCoast).source == .remote)
        let productionClient = try AssetClient(configuration: production, storage: FileAssetStorage(configuration: production, root: root), transport: transport)
        #expect(await productionClient.initialize().sequence == 0)
        #expect(await productionClient.resolve(variantCoast, download: false).source == .bundle)
    }

    @Test func signedVariantsRejectMalformedAxesCoordinatesAndImages() throws {
        let f = try SignedVariants()
        var invalid: [(String, [String: Any])] = []
        for version: Any in [NSNull(), 2, true, "1", 1.5] {
            var p = f.original; p["variantSchemaVersion"] = version; invalid.append(("version \(version)", p))
        }
        for axes: Any in [NSNull(), [], [:], ["appearance": NSNull()], ["appearance": []], ["appearance": ["dark", "dark"]], ["appearance": ["light", "dark", "light"]], ["appearance": ["any"]], ["appearance": [1]], ["arm": NSNull()], ["arm": []], ["arm": ["b", "b"]], ["arm": ["a", "b", "c", "d", "e"]], ["unknown": ["b"]], ["arm": ["b"], "unknown": ["ignored"]]] {
            var s = f.slot; s["variants"] = axes; invalid.append(("axes \(axes)", f.payload(slot: s)))
        }
        for arm in ["control", "any", "constructor", "prototype", "__proto__", "B", "1b", "b!", " b", "b ", "b\n", String(repeating: "b", count: 21)] {
            var s = f.slot; s["variants"] = ["arm": [arm]]; s.removeValue(forKey: "cells")
            invalid.append(("reserved or malformed arm \(arm)", f.payload(slot: s)))
        }
        for cells: Any in [NSNull(), [:], "bad", [f.cells[0], f.cells[0]], Array(repeating: f.cells[0], count: 4)] {
            var s = f.slot; s["cells"] = cells; invalid.append(("cells \(cells)", f.payload(slot: s)))
        }
        for (field, value): (String, Any) in [
            ("appearance", NSNull()), ("appearance", "light"), ("appearance", "Dark"), ("arm", NSNull()), ("arm", "c"),
            ("arm", "control"), ("assetId", "invalid"), ("sha256", "bad"), ("sha256", String(repeating: "A", count: 64)),
            ("mime", "image/png"), ("bytes", 0), ("bytes", true), ("bytes", 1.5), ("bytes", AssetLimits.assetBytes + 1),
            ("url", f.cells[0]["url"] as! String + "?token=x"), ("url", "https://evil.example" + (f.cells[0]["url"] as! String)),
            ("url", f.slot["url"] as! String), ("accessibility", NSNull()),
            ("accessibility", ["defaultLocale": "en", "descriptions": ["en": " "]]), ("renditions", NSNull()), ("renditions", [])
        ] {
            var cell = f.cells[0]; cell[field] = value
            var s = f.slot; s["cells"] = [cell]; invalid.append(("cell \(field): \(value)", f.payload(slot: s)))
        }
        var coordinateFree = f.cells[0]; coordinateFree.removeValue(forKey: "arm")
        var s = f.slot; s["cells"] = [coordinateFree]; invalid.append(("missing coordinates", f.payload(slot: s)))
        s = f.slot; s.removeValue(forKey: "variants"); invalid.append(("missing variants", f.payload(slot: s)))
        var missingVersion = f.original; missingVersion.removeValue(forKey: "variantSchemaVersion"); invalid.append(("missing version", missingVersion))
        s = f.slot; s.removeValue(forKey: "cells")
        var axesWithoutVersion = f.payload(slot: s); axesWithoutVersion.removeValue(forKey: "variantSchemaVersion")
        invalid.append(("unversioned axes", axesWithoutVersion))
        for (label, payload) in invalid {
            #expect(throws: AssetLibError.self, "\(label)") { _ = try ManifestVerifier.verify(f.envelope(payload), config: f.configuration) }
        }
        // Native state sets and unrelated future keys are deliberately ignored.
        var validCell = f.cells[0]; validCell["states"] = ["bad": NSNull()]; validCell["future"] = 42
        s = f.slot; s["cells"] = [validCell]; s["future"] = ["ignored": true]
        s["variants"] = ["arm": ["b"]]
        var futurePayload = f.payload(slot: s); futurePayload["future"] = ["ignored": true]
        #expect(throws: Never.self) { _ = try ManifestVerifier.verify(f.envelope(futurePayload), config: f.configuration) }
        s["cells"] = []
        #expect(throws: Never.self) { _ = try ManifestVerifier.verify(f.envelope(f.payload(slot: s)), config: f.configuration) }
        s.removeValue(forKey: "cells")
        #expect(throws: Never.self) { _ = try ManifestVerifier.verify(f.envelope(f.payload(slot: s)), config: f.configuration) }
    }

    @Test func decisionsValidateResultsAndExplicitOverridesSkipCallback() async throws {
        let f = try SignedVariants()
        for answer: String? in [nil, "", "control", "zzz", "b"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let decisions = Decisions(answer)
            let transport = VariantTransport(manifest: try f.manifest(), objects: try variantObjects(f.configuration))
            let client = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport,
                decide: { key, arms in await decisions.decide(key, arms) })
            _ = await client.refresh()
            let result = await client.resolve(variantCoast, appearance: .dark)
            #expect(result.assetID == (answer == "b" ? coastID : ridgeID))
            #expect(result.arm == (answer == "b" ? "b" : nil))
            #expect(result.armSource == (answer == "b" ? .decision : .invalidDecision))
            #expect(await decisions.calls == [.init(key: variantCoast.key, arms: ["b"])])
            await decisions.reset()
            for arm in ["b", "control", "zzz"] {
                #expect(await client.resolve(variantCoast, appearance: .dark, arm: arm).armSource == .explicit)
            }
            #expect(await decisions.calls.isEmpty)
            _ = await client.resolve(.init(key: variantCoast.key, width: 1, height: 1))
            _ = await client.resolve(.init(key: "missing.artwork", width: 1200, height: 900))
            #expect(await decisions.calls.isEmpty)
        }
    }

    @Test func selectedCellUsesItsOwnRenditionsAndAccessibility() async throws {
        let f = try SignedVariants(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try variantFixture("assets/medium.png")
        let path = f.cells[1]["url"] as! String
        let rendition: [String: Any] = ["sha256": hashBytes(png), "url": path + "/renditions/" + hashBytes(png),
            "mime": "image/png", "bytes": png.count, "width": 480, "height": 360]
        var cell = f.cells[1]
        cell["renditions"] = [rendition]
        cell["accessibility"] = ["defaultLocale": "en", "descriptions": ["en": "Dark ridge"]]
        var slot = f.slot; slot["cells"] = [cell]
        slot["accessibility"] = ["defaultLocale": "en", "descriptions": ["en": "Base coast"]]
        var payload = f.payload(slot: slot); payload["renditionSchemaVersion"] = 1
        let transport = VariantTransport(manifest: try f.manifest(payload), objects: [rendition["url"] as! String: png])
        let client = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport)
        #expect(await client.refresh().error == nil)
        let selected = await client.resolve(variantCoast, targetPixels: .init(width: 300, height: 225), appearance: .dark)
        #expect(selected.source == .remote && selected.assetID == ridgeID && selected.mime == "image/png")
        #expect(selected.pixelSize == AssetPixelSize(width: 480, height: 360) && selected.appearance == .dark)
        #expect(selected.accessibility?.localizedDescription(languageTag: "en") == "Dark ridge")
        #expect(await client.resolve(variantCoast, download: false, appearance: .light).source == .bundle)
        var undescribedCell = cell; undescribedCell.removeValue(forKey: "accessibility")
        var revisedSlot = slot; revisedSlot["cells"] = [undescribedCell]
        var revised = f.payload(sequence: 7, slot: revisedSlot); revised["renditionSchemaVersion"] = 1
        await transport.update(manifest: try f.manifest(revised), objects: [:])
        #expect(await client.refresh().sequence == 7)
        let undescribed = await client.resolve(variantCoast, targetPixels: .init(width: 300, height: 225), appearance: .dark)
        #expect(undescribed.source == .cache && undescribed.sha256 == selected.sha256 && undescribed.sequence == 7)
        #expect(undescribed.accessibility == nil)
        var noVersion = payload; noVersion.removeValue(forKey: "renditionSchemaVersion")
        #expect(throws: AssetLibError.self) { _ = try ManifestVerifier.verify(f.envelope(noVersion), config: f.configuration) }
        for renditions: Any in [[], NSNull(), [rendition, rendition], Array(repeating: rendition, count: 8)] {
            var c = cell; c["renditions"] = renditions
            var s = slot; s["cells"] = [c]
            var p = f.payload(slot: s); p["renditionSchemaVersion"] = 1
            #expect(throws: AssetLibError.self) { _ = try ManifestVerifier.verify(f.envelope(p), config: f.configuration) }
        }
        for (field, value): (String, Any) in [
            ("sha256", "bad"), ("mime", "image/jpeg"), ("bytes", 0), ("bytes", AssetLimits.assetBytes + 1),
            ("width", 0), ("width", true), ("width", 600.5), ("width", 8193), ("height", 1),
            ("url", (f.slot["url"] as! String) + "/renditions/" + hashBytes(png)),
            ("url", path + "/renditions/" + String(repeating: "a", count: 64)),
            ("url", (rendition["url"] as! String) + "#fragment")
        ] {
            var r = rendition; r[field] = value
            var c = cell; c["renditions"] = [r]
            var s = slot; s["cells"] = [c]
            var p = f.payload(slot: s); p["renditionSchemaVersion"] = 1
            #expect(throws: AssetLibError.self, "Cell rendition \(field): \(value)") { _ = try ManifestVerifier.verify(f.envelope(p), config: f.configuration) }
        }
    }

    @Test func cellCachesStayIsolatedAcrossAppearanceArmsHistoryAndRestart() async throws {
        let f = try SignedVariants(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let decisions = Decisions("b")
        let transport = VariantTransport(manifest: try f.manifest(), objects: try variantObjects(f.configuration))
        let storage = try FileAssetStorage(configuration: f.configuration, root: root)
        let client = try AssetClient(configuration: f.configuration, storage: storage, transport: transport,
            decide: { key, arms in await decisions.decide(key, arms) })
        _ = await client.refresh()
        let dark = await client.resolve(variantCoast, appearance: .dark, arm: "control")
        #expect(dark.source == .remote && dark.assetID == ridgeID && dark.appearance == .dark)
        #expect(await client.resolve(variantCoast, download: false, appearance: .light, arm: "control").source == .bundle)
        #expect(await client.resolve(variantCoast, download: false, appearance: .dark, arm: "b").source == .bundle)
        let light = await client.resolve(variantCoast, appearance: .light, arm: "control")
        #expect(light.source == .remote && light.assetID == coastID && light.appearance == nil)
        var nextSlot = f.slot
        nextSlot["sha256"] = String(repeating: "c", count: 64)
        var nextCells = f.cells
        for index in nextCells.indices { nextCells[index]["sha256"] = String(repeating: "d", count: 64) }
        nextSlot["cells"] = nextCells
        await transport.update(manifest: try f.manifest(f.payload(sequence: 7, slot: nextSlot)), objects: [:])
        #expect(await client.refresh().sequence == 7)
        await decisions.reset(); await transport.resetRequests()
        let historical = await client.resolve(variantCoast, appearance: .dark)
        #expect(historical.source == .cache && historical.sequence == 6 && historical.assetID == coastID)
        #expect(historical.arm == "b" && historical.appearance == .dark && historical.armSource == .decision)
        #expect(await decisions.calls.count == 1)
        #expect(await transport.requests.count == 1)
        let restarted = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport)
        await transport.resetRequests()
        let oldDark = await restarted.resolve(variantCoast, download: false, appearance: .dark)
        let oldLight = await restarted.resolve(variantCoast, download: false, appearance: .light)
        #expect(oldDark.source == .cache && oldDark.sequence == 6 && oldDark.assetID == ridgeID && oldDark.appearance == .dark)
        #expect(oldLight.source == .cache && oldLight.sequence == 6 && oldLight.assetID == coastID && oldLight.appearance == nil)
        #expect(await transport.requests.isEmpty)
        // Latest declared arms determine the one decision; historical-only arms cannot be selected.
        nextSlot["variants"] = ["arm": ["c"]]
        nextSlot["cells"] = []
        await transport.update(manifest: try f.manifest(f.payload(sequence: 8, slot: nextSlot)), objects: [:])
        _ = await client.refresh(); await decisions.reset()
        let invalidDecision = await client.resolve(variantCoast, appearance: .dark)
        #expect(invalidDecision.assetID == ridgeID && invalidDecision.arm == nil && invalidDecision.armSource == .invalidDecision)
        #expect(await decisions.calls == [.init(key: variantCoast.key, arms: ["c"])])
        nextSlot.removeValue(forKey: "variants"); nextSlot.removeValue(forKey: "cells")
        await transport.update(manifest: try f.manifest(f.payload(sequence: 9, slot: nextSlot)), objects: [:])
        _ = await client.refresh(); await decisions.reset()
        #expect(await client.resolve(variantCoast, appearance: .dark).armSource == .control)
        #expect(await decisions.calls.isEmpty)
        nextSlot["width"] = 1; nextSlot["height"] = 1
        nextSlot["variants"] = ["arm": ["b"]]
        await transport.update(manifest: try f.manifest(f.payload(sequence: 10, slot: nextSlot)), objects: [:])
        _ = await client.refresh(); await decisions.reset()
        #expect(await client.resolve(variantCoast, appearance: .dark).armSource == .control)
        #expect(await decisions.calls.isEmpty)
    }

    @MainActor @Test func imageStorePropagatesAppearanceAndArmAndInvalidatesOldResults() async throws {
        let f = try SignedVariants(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = VariantTransport(manifest: try f.manifest(), objects: try variantObjects(f.configuration))
        let store = AssetImageStore()
        store.connect(try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport))
        store.appearance = .dark
        store.arm = [variantCoast: "b"]
        await store.refresh([variantCoast])
        #expect(store.results[variantCoast]?.assetID == coastID && store.results[variantCoast]?.arm == "b")
        #expect(store.results[variantCoast]?.appearance == .dark)
        store.appearance = .light
        #expect(store.results.isEmpty)
        await store.refresh([variantCoast])
        #expect(store.results[variantCoast]?.assetID == ridgeID && store.results[variantCoast]?.appearance == nil)
        store.arm[variantCoast] = "control"
        #expect(store.results.isEmpty)
        await store.refresh([variantCoast])
        #expect(store.results[variantCoast]?.assetID == coastID && store.results[variantCoast]?.arm == nil)
        #expect(store.results[variantCoast]?.armSource == .explicit)
    }

    @MainActor @Test func selectionChangesRejectInFlightStoreResults() async throws {
        let f = try SignedVariants()
        for changeAppearance in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = GatedDecision()
            let transport = VariantTransport(manifest: try f.manifest(), objects: try variantObjects(f.configuration))
            let client = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport,
                decide: { _, _ in await gate.decide() })
            _ = await client.refresh()
            #expect(await client.resolve(variantCoast, appearance: .dark, arm: "b").source == .remote)
            let store = AssetImageStore()
            store.connect(client); store.appearance = .dark
            let pending = Task { await store.refresh([variantCoast]) }
            await gate.waitUntilCalled()
            #expect(store.isLoading)
            if changeAppearance { store.appearance = .light } else { store.arm[variantCoast] = "control" }
            #expect(store.results.isEmpty && !store.isLoading)
            await gate.release()
            await pending.value
            #expect(store.results.isEmpty && !store.isLoading && store.connected)
        }
    }
}
