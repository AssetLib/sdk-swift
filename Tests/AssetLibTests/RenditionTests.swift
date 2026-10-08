import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import Testing
@testable import AssetLib

private func renditionFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
}
private func png(width: Int, height: Int, blue: CGFloat = 0.6) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct SignedRenditions {
    // TEST ONLY. This deterministic key signs synthetic fixtures, never a service configuration.
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x31, count: 32))
    let configuration: AssetConfiguration
    let original: [String: Any]
    let legacy: Data
    let small: Data
    let medium: Data
    let large: Data
    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 600 450\"><path d=\"M0 0h600v450H0z\"/></svg>".utf8)
    let reference = AssetReference(key: "travel.coast", width: 600, height: 450)

    init() throws {
        var config = try JSONSerialization.jsonObject(with: renditionFixture("config.json")) as! [String: Any]
        let prefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00])
        let pem = "-----BEGIN PUBLIC KEY-----\n" + (prefix + key.publicKey.rawRepresentation).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
        config["pinnedPublicKey"] = pem; config.removeValue(forKey: "keyId")
        configuration = try .parse(JSONSerialization.data(withJSONObject: config))
        let envelope = try JSONDecoder().decode(SignedManifest.self, from: renditionFixture("manifests/valid-logical-dimensions.json"))
        original = try JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as! [String: Any]
        legacy = try renditionFixture("assets/coast.webp")
        small = try png(width: 300, height: 225)
        medium = try png(width: 600, height: 450)
        large = try png(width: 1200, height: 900)
    }
    var slot: [String: Any] { (original["slots"] as! [[String: Any]])[0] }
    var basePath: String { "/api/delivery/\(configuration.orgId)/\(configuration.appId)/assets/\(slot["assetId"] as! String)" }
    func rendition(_ data: Data, width: Int, height: Int, mime: String = "image/png") -> [String: Any] {
        ["sha256": hashBytes(data), "url": basePath + "/renditions/" + hashBytes(data), "mime": mime,
         "bytes": data.count, "width": width, "height": height]
    }
    var variants: [[String: Any]] {
        [rendition(svg, width: 600, height: 450, mime: "image/svg+xml"),
         rendition(large, width: 1200, height: 900), rendition(small, width: 300, height: 225),
         rendition(medium, width: 600, height: 450)]
    }
    func payload(sequence: Int = 1, variants: [[String: Any]]? = nil) -> [String: Any] {
        var p = original, s = slot
        p["sequence"] = sequence; p["renditionSchemaVersion"] = 1
        s["renditions"] = variants ?? self.variants; p["slots"] = [s]
        return p
    }
    func envelope(_ payload: [String: Any]) throws -> SignedManifest {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        return SignedManifest(algorithm: "Ed25519", keyId: configuration.signingKeyID,
            publicKey: configuration.pinnedPublicKey, payload: text, signature: try key.signature(for: Data(text.utf8)).base64EncodedString())
    }
    func manifest(sequence: Int = 1) throws -> Data { try JSONEncoder().encode(envelope(payload(sequence: sequence))) }
    var objects: [String: Data] {
        [basePath: legacy, basePath + "/renditions/" + hashBytes(small): small,
         basePath + "/renditions/" + hashBytes(medium): medium, basePath + "/renditions/" + hashBytes(large): large]
    }
}

private actor RenditionTransport: AssetTransport {
    var manifest: Data
    var objects: [String: Data]
    var requests: [String] = []
    var accepts: [String] = []
    init(manifest: Data, objects: [String: Data]) { self.manifest = manifest; self.objects = objects }
    func update(manifest: Data, objects: [String: Data]) { self.manifest = manifest; self.objects = objects }
    func resetRequests() { requests = []; accepts = [] }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        requests.append(url.path); accepts.append(accept)
        let data = url.path.hasSuffix("/manifest") ? manifest : objects[url.path]
        guard let data, data.count <= maximumBytes else { throw AssetLibError.invalid("Offline or unavailable rendition") }
        return data
    }
}

@Suite struct RenditionTests {
    @Test func sharedRenditionSelectionAndNativeDecoding() async throws {
        struct Matrix: Decodable {
            struct File: Decodable { let file: String; let sha256: String }
            struct Selection: Decodable { let width: Int; let height: Int; let mime: String; let sha256: String }
            let manifest: String
            let files: [File]
            let selections: [Selection]
        }
        let matrix = try JSONDecoder().decode(Matrix.self, from: renditionFixture("renditions.json"))
        let configuration = try AssetConfiguration.parse(renditionFixture("config.json"))
        let manifest = try renditionFixture(matrix.manifest)
        let payload = try ManifestVerifier.verify(JSONDecoder().decode(SignedManifest.self, from: manifest), config: configuration)
        let slot = payload.slots[0]
        var objects: [String: Data] = [:]
        for file in matrix.files {
            let bytes = try renditionFixture(file.file)
            #expect(hashBytes(bytes) == file.sha256)
            for candidate in (slot.renditions ?? []).filter({ $0.sha256 == file.sha256 }) {
                objects[try ManifestVerifier.candidateURL(AssetCandidate(candidate), assetID: slot.assetId, config: configuration).path] = bytes
            }
            if slot.sha256 == file.sha256 { objects[try ManifestVerifier.assetURL(slot, config: configuration).path] = bytes }
        }
        for selection in matrix.selections {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = RenditionTransport(manifest: manifest, objects: objects)
            let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
            #expect(await client.refresh().sequence == 4)
            let resolved = await client.resolve(.init(key: slot.key, width: slot.width, height: slot.height), targetPixels: .init(width: selection.width, height: selection.height))
            #expect(resolved.source == .remote && resolved.sha256 == selection.sha256 && resolved.mime == selection.mime)
            #expect(resolved.pixelSize != nil)
            #expect(!(await transport.accepts).contains("image/svg+xml"))
        }
    }

    @Test func signedExtensionRejectsMalformedMetadata() throws {
        let f = try SignedRenditions()
        #expect(throws: Never.self) { _ = try ManifestVerifier.verify(f.envelope(f.payload()), config: f.configuration) }
        // An extension version may exist while legacy placements have no renditions.
        var legacy = f.original; legacy["renditionSchemaVersion"] = 1
        #expect(throws: Never.self) { _ = try ManifestVerifier.verify(f.envelope(legacy), config: f.configuration) }
        var mutations: [[String: Any]] = []
        for version: Any in [NSNull(), 2, true, "1", 1.5] {
            var p = f.payload(); p["renditionSchemaVersion"] = version; mutations.append(p)
        }
        var noVersion = f.payload(); noVersion.removeValue(forKey: "renditionSchemaVersion"); mutations.append(noVersion)
        for renditions: Any in [NSNull(), [], [f.variants[1], f.variants[1]], Array(repeating: f.variants[1], count: 8)] {
            var p = f.payload(), s = f.slot; s["renditions"] = renditions; p["slots"] = [s]; mutations.append(p)
        }
        let changes: [(String, Any)] = [
            ("width", 0), ("width", true), ("width", 600.5), ("width", 8193), ("height", 1),
            ("bytes", 0), ("bytes", AssetLimits.assetBytes + 1), ("mime", "image/jpeg"),
            ("sha256", "wrong"), ("url", "https://other.example" + f.basePath + "/renditions/" + hashBytes(f.medium)),
            ("url", f.basePath + "/renditions/" + hashBytes(f.medium) + "?x=1"),
            ("url", f.basePath + "/renditions/" + hashBytes(f.medium) + "#fragment"),
            ("url", f.basePath + "/renditions/" + String(repeating: "a", count: 64)),
            ("url", f.basePath + "/renditions%2F" + hashBytes(f.medium))
        ]
        for (field, value) in changes {
            var r = f.variants[3]; r[field] = value; mutations.append(f.payload(variants: [r]))
        }
        var largeSVG = f.variants[0]; largeSVG["bytes"] = 262_145; mutations.append(f.payload(variants: [largeSVG]))
        var manyPixels = f.variants[1]; manyPixels["width"] = 6000; manyPixels["height"] = 4500
        mutations.append(f.payload(variants: [manyPixels]))
        for (index, p) in mutations.enumerated() {
            #expect(throws: (any Error).self, "Malformed rendition \(index)") { _ = try ManifestVerifier.verify(f.envelope(p), config: f.configuration) }
        }
    }

    @Test func nativePNGRequiresExactDimensionsAndActualType() throws {
        let f = try SignedRenditions()
        let payload = try ManifestVerifier.verify(f.envelope(f.payload()), config: f.configuration)
        let rendition = try #require(payload.slots[0].renditions?.first { $0.sha256 == hashBytes(f.medium) })
        #expect(ManifestVerifier.decodedSize(f.medium, candidate: AssetCandidate(rendition)) == AssetPixelSize(width: 600, height: 450))
        let wrongSize = ManifestRendition(sha256: rendition.sha256, url: rendition.url, mime: rendition.mime, bytes: rendition.bytes, width: 300, height: 225)
        #expect(ManifestVerifier.decodedSize(f.medium, candidate: AssetCandidate(wrongSize)) == nil)
        let wrongType = ManifestRendition(sha256: rendition.sha256, url: rendition.url, mime: "image/webp", bytes: rendition.bytes, width: 600, height: 450)
        #expect(ManifestVerifier.decodedSize(f.medium, candidate: AssetCandidate(wrongType)) == nil)
        var corrupt = f.medium; corrupt[corrupt.count / 2] ^= 0x80
        #expect(ManifestVerifier.decodedSize(corrupt, candidate: AssetCandidate(rendition)) == nil)
        let truncated = Data(f.medium.prefix(20))
        let signedTruncated = ManifestRendition(sha256: hashBytes(truncated), url: rendition.url, mime: "image/png", bytes: truncated.count, width: 600, height: 450)
        #expect(ManifestVerifier.decodedSize(truncated, candidate: AssetCandidate(signedTruncated)) == nil)
    }

    @Test func targetSelectionPNGOfflineRestartAndLegacyCacheMigration() async throws {
        let f = try SignedRenditions(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RenditionTransport(manifest: try f.manifest(), objects: f.objects)
        let storage = try FileAssetStorage(configuration: f.configuration, root: root)
        let client = try AssetClient(configuration: f.configuration, storage: storage, transport: transport)
        #expect(await client.refresh().error == nil)
        let medium = await client.resolve(f.reference)
        #expect(medium.source == .remote && medium.mime == "image/png" && medium.sha256 == hashBytes(f.medium))
        #expect(medium.pixelSize == AssetPixelSize(width: 600, height: 450) && medium.assetID == f.slot["assetId"] as? String)
        let small = await client.resolve(f.reference, targetPixels: .init(width: 200, height: 150))
        #expect(small.sha256 == hashBytes(f.small))
        let largest = await client.resolve(f.reference, targetPixels: .init(width: 2000, height: 1500))
        #expect(largest.sha256 == hashBytes(f.large))
        #expect(await client.resolve(f.reference, targetPixels: .init(width: 0, height: 100)).source == .bundle)
        #expect(!(await transport.accepts).contains("image/svg+xml"))
        await transport.update(manifest: Data(), objects: [:]); await transport.resetRequests()
        let restarted = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport)
        let cached = await restarted.resolve(f.reference)
        #expect(cached.source == .cache && cached.mime == "image/png" && cached.sha256 == medium.sha256)
        #expect((await transport.requests).isEmpty)
        // Old releases used a .webp filename. Upgrade must still read that verified cache.
        let oldFile = root.appendingPathComponent(f.configuration.storageNamespace).appendingPathComponent(hashBytes(f.legacy) + ".webp")
        try f.legacy.write(to: oldFile)
        let legacyOnly = try AssetClient(configuration: f.configuration, storage: storage, transport: transport, supportedFormats: [.webP])
        let migrated = await legacyOnly.resolve(f.reference)
        #expect(migrated.source == .cache && migrated.mime == "image/webp" && migrated.sha256 == hashBytes(f.legacy))
        #expect(migrated.pixelSize == AssetPixelSize(width: 1200, height: 900))
    }

    @Test func candidateFailuresContinueThenUseHistoricalCacheOnly() async throws {
        let f = try SignedRenditions(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RenditionTransport(manifest: try f.manifest(), objects: f.objects)
        let client = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport)
        _ = await client.refresh()
        let first = await client.resolve(f.reference)
        #expect(first.mime == "image/png")
        // Current release references genuinely new content; all its transfers fail.
        let unavailable = try png(width: 600, height: 450, blue: 0.2)
        var second = f.payload(sequence: 2, variants: [f.rendition(unavailable, width: 600, height: 450)])
        var slots = second["slots"] as! [[String: Any]]
        slots[0]["sha256"] = String(repeating: "a", count: 64); second["slots"] = slots
        await transport.update(manifest: try JSONEncoder().encode(f.envelope(second)), objects: [:])
        #expect(await client.refresh().sequence == 2)
        await transport.resetRequests()
        let fallback = await client.resolve(f.reference)
        #expect(fallback.source == .cache && fallback.sequence == 1 && fallback.sha256 == first.sha256)
        #expect(await transport.requests == [f.basePath + "/renditions/" + hashBytes(unavailable), f.basePath])
        // A fresh device attempts a bad PNG, then a larger good PNG before legacy WebP.
        let freshRoot = root.appendingPathComponent("fresh")
        var objects = f.objects; objects[f.basePath + "/renditions/" + hashBytes(f.medium)] = Data("bad".utf8)
        await transport.update(manifest: try f.manifest(), objects: objects); await transport.resetRequests()
        let fresh = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: freshRoot), transport: transport)
        _ = await fresh.refresh()
        #expect(await fresh.resolve(f.reference).sha256 == hashBytes(f.large))
        #expect(!(await transport.requests).contains(f.basePath))
        // If every rendition fails, the mandatory legacy WebP still works.
        let legacyRoot = root.appendingPathComponent("legacy")
        await transport.update(manifest: try f.manifest(), objects: [f.basePath: f.legacy])
        let legacy = try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: legacyRoot), transport: transport)
        _ = await legacy.refresh()
        #expect(await legacy.resolve(f.reference).mime == "image/webp")
    }

    @Test func deterministicTiesAndInvalidFormatLists() throws {
        let f = try SignedRenditions()
        var a = f.variants[3], b = a
        a["sha256"] = String(repeating: "a", count: 64); a["url"] = f.basePath + "/renditions/" + (a["sha256"] as! String)
        b["sha256"] = String(repeating: "b", count: 64); b["url"] = f.basePath + "/renditions/" + (b["sha256"] as! String)
        let payload = try ManifestVerifier.verify(f.envelope(f.payload(variants: [b, a])), config: f.configuration)
        let candidates = ManifestVerifier.candidates(payload.slots[0], target: .init(width: 600, height: 450), formats: [.webP, .png])
        #expect(candidates[0].sha256 == a["sha256"] as? String && candidates.last?.isLegacy == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try FileAssetStorage(configuration: f.configuration, root: root)
        for formats: [AssetFormat] in [[], [.png], [.webP, .webP]] {
            #expect(throws: (any Error).self) { _ = try AssetClient(configuration: f.configuration, storage: storage, supportedFormats: formats) }
        }
    }

    @MainActor @Test func imageStoreUsesExplicitTargetsAndKeepsNativeGetter() async throws {
        let f = try SignedRenditions(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RenditionTransport(manifest: try f.manifest(), objects: f.objects)
        let store = AssetImageStore()
        store.connect(try AssetClient(configuration: f.configuration, storage: FileAssetStorage(configuration: f.configuration, root: root), transport: transport))
        await store.refresh([f.reference], targetPixels: [f.reference: .init(width: 200, height: 150)])
        #expect(store.results[f.reference]?.pixelSize == AssetPixelSize(width: 300, height: 225))
        #expect(store.results[f.reference]?.mime == "image/png")
        #expect(!store.isLoading && store.connected)
        // The same reference can ask for a larger rendition without changing its generated symbol.
        await store.refresh([f.reference], targetPixels: [f.reference: .init(width: 700, height: 525)])
        #expect(store.results[f.reference]?.pixelSize == AssetPixelSize(width: 1200, height: 900))
    }
}
