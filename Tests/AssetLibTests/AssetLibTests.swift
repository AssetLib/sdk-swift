import Foundation
import Testing
@testable import AssetLib

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
}
private func config() throws -> AssetConfiguration { try .parse(fixture("config.json")) }
private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private let coast = AssetReference(key: "travel.coast", width: 1200, height: 900)

private actor FixtureTransport: AssetTransport {
    var manifest: Data
    var image: Data?
    var online = true
    init(_ manifest: String = "manifests/valid-seq1.json", image: String? = "assets/coast.webp") throws {
        self.manifest = try fixture(manifest)
        self.image = try image.map(fixture)
    }
    func set(manifest: String, image: String?) throws { self.manifest = try fixture(manifest); self.image = try image.map(fixture) }
    func goOffline() { online = false }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        guard online else { throw AssetLibError.invalid("Offline") }
        let data = url.path.hasSuffix("/manifest") ? manifest : image
        guard let data else { throw AssetLibError.invalid("Missing image") }
        guard data.count <= maximumBytes else { throw AssetLibError.invalid("Response exceeds limit") }
        return data
    }
}

@Suite struct ProtocolTests {
    @Test func sharedInteropManifestCases() throws {
        struct Cases: Decodable {
            struct Entry: Decodable { let file: String; let verification: String }
            let manifests: [Entry]
        }
        let cases = try JSONDecoder().decode(Cases.self, from: fixture("cases.json"))
        for entry in cases.manifests {
            let envelope = try JSONDecoder().decode(SignedManifest.self, from: fixture(entry.file))
            if entry.verification == "accept" {
                #expect(throws: Never.self, "\(entry.file)") { _ = try ManifestVerifier.verify(envelope, config: config()) }
            } else {
                #expect(throws: (any Error).self, "\(entry.file)") { _ = try ManifestVerifier.verify(envelope, config: config()) }
            }
        }
    }

    @Test func rejectsUnsafePublicConfiguration() throws {
        let original = try JSONSerialization.jsonObject(with: fixture("config.json")) as! [String: Any]
        for (field, value) in [("manifestUrl", "http://fixtures.assetlib.example/api/delivery/x/y/manifest"), ("keyId", "bad"), ("environment", "staging"), ("orgId", "wrong"), ("pinnedPublicKey", "invalid")] {
            var object = original; object[field] = value
            let bytes = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { _ = try AssetConfiguration.parse(bytes) }
        }
        for suffix in ["?token=x", "#fragment", "/", "%2f"] {
            var object = original; object["manifestUrl"] = (original["manifestUrl"] as! String) + suffix
            #expect(throws: (any Error).self) { _ = try AssetConfiguration.parse(JSONSerialization.data(withJSONObject: object)) }
        }
    }

    @Test func validatesNativeWebPAndLogicalDimensions() throws {
        let envelope = try JSONDecoder().decode(SignedManifest.self, from: fixture("manifests/valid-logical-dimensions.json"))
        let slot = try ManifestVerifier.verify(envelope, config: config()).slots[0]
        #expect(slot.width == 600 && slot.height == 450)
        #expect(ManifestVerifier.validAsset(try fixture("assets/coast.webp"), slot: slot))
        #expect(!ManifestVerifier.validAsset(try fixture("assets/ridge-tampered.webp"), slot: slot))
        #expect(!ManifestVerifier.validAsset(try fixture("assets/ridge-truncated.webp"), slot: slot))
    }

    @Test func publicationRollbackOfflineRestartAndWrongPlacement() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config()
        let transport = try FixtureTransport()
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        let client = try AssetClient(configuration: configuration, storage: storage, transport: transport)
        #expect(await client.refresh().sequence == 1)
        let first = await client.resolve(coast)
        #expect(first.source == .remote && first.sequence == 1)
        await #expect(throws: Never.self) { try await transport.set(manifest: "manifests/valid-seq2.json", image: "assets/ridge.webp") }
        #expect(await client.refresh().sequence == 2)
        let second = await client.resolve(coast)
        #expect(second.source == .remote && second.sha256 != first.sha256)
        try await transport.set(manifest: "manifests/valid-rollback-seq3.json", image: "assets/coast.webp")
        #expect(await client.refresh().sequence == 3)
        let restored = await client.resolve(coast)
        #expect(restored.source == .cache && restored.sha256 == first.sha256 && restored.sequence == 3)
        await transport.goOffline()
        let restarted = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        #expect(await restarted.refresh().sequence == 3)
        let offline = await restarted.resolve(coast)
        #expect(offline.source == .cache && offline.sha256 == first.sha256)
        #expect(await restarted.resolve(.init(key: "travel.coast", width: 1, height: 1)).source == .bundle)
    }

    @Test func persistedStaleEquivocationAndIdempotence() async throws {
        for file in ["stateful/stale-seq1", "stateful/equivocation-seq2", "stateful/reformatted-seq2", "stateful/unicode-equivalent-seq2", "valid-seq2"] {
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let configuration = try config()
            let storage = try FileAssetStorage(configuration: configuration, root: root)
            try await storage.saveState(fixture("state/after-seq2.json"))
            let client = try AssetClient(configuration: configuration, storage: storage, transport: FixtureTransport("manifests/\(file).json"))
            let result = await client.refresh()
            #expect(result.sequence == 2 && !result.updated)
            #expect((result.error == nil) == (file == "valid-seq2"))
        }
    }

    @Test func failedNewArtworkFallsBackToOlderVerifiedCache() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config()
        let transport = try FixtureTransport()
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        _ = await client.refresh()
        let first = await client.resolve(coast)
        for bad in ["ridge-tampered.webp", "ridge-truncated.webp"] {
            try await transport.set(manifest: "manifests/valid-seq2.json", image: "assets/\(bad)")
            _ = await client.refresh()
            let fallback = await client.resolve(coast)
            #expect(fallback.source == .cache && fallback.sequence == 1 && fallback.sha256 == first.sha256)
        }
    }

    @Test func independentClientsCannotOverwriteHigherSequence() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config()
        let older = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: FixtureTransport())
        let newer = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: FixtureTransport("manifests/valid-seq2.json"))
        _ = await older.initialize(); _ = await newer.initialize()
        #expect(await newer.refresh().sequence == 2)
        #expect(await older.refresh().error != nil)
        #expect(await older.initialize().sequence == 2)
        let saved = try await FileAssetStorage(configuration: configuration, root: root).loadState()
        #expect(try JSONDecoder().decode(PersistedState.self, from: #require(saved)).highestSequence == 2)
    }

    @Test func corruptedDurableStateFailsClosed() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config()
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        let path = root.appendingPathComponent(configuration.storageNamespace).appendingPathComponent("state.json")
        try Data("{invalid".utf8).write(to: path)
        let client = try AssetClient(configuration: configuration, storage: storage, transport: FixtureTransport())
        #expect(await client.refresh().error != nil)
        #expect(await client.resolve(coast).source == .bundle)
        #expect(try Data(contentsOf: path) == Data("{invalid".utf8))
    }

    @Test func liveClientDetectsLaterDiskCorruption() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config()
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        let client = try AssetClient(configuration: configuration, storage: storage, transport: FixtureTransport())
        _ = await client.refresh(); _ = await client.resolve(coast)
        let path = root.appendingPathComponent(configuration.storageNamespace).appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: path)
        #expect(await client.resolve(coast).source == .bundle)
        #expect(await client.refresh().error != nil)
        #expect(throws: (any Error).self) { try ManifestVerifier.verifiedState(Data("{}".utf8), config: configuration) }
    }

    @MainActor @Test func disconnectRejectsInFlightStoreUpdates() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try config()
        let store = AssetImageStore()
        store.connect(try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: FixtureTransport()))
        let pending = Task { await store.refresh([coast]) }
        await Task.yield()
        store.disconnect()
        await pending.value
        #expect(!store.connected && store.results.isEmpty && store.release == 0 && !store.isLoading)
    }
}

@Suite struct HostedAcceptance {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ASSETLIB_PUBLIC_CONFIG_FILE"] != nil))
    func readOnlyHostedSignatureWebPAndOfflineRestart() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ASSETLIB_PUBLIC_CONFIG_FILE"])
        let configuration = try AssetConfiguration.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root))
        let refreshed = await client.refresh()
        #expect(refreshed.error == nil && refreshed.sequence > 0)
        let refs = [coast, AssetReference(key: "travel.ridge", width: 1200, height: 900), AssetReference(key: "tasks.garden", width: 600, height: 400)]
        for ref in refs { #expect(await client.resolve(ref).source == .remote) }
        let offline = try FixtureTransport(); await offline.goOffline()
        let restarted = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: offline)
        #expect(await restarted.initialize().sequence == refreshed.sequence)
        for ref in refs { #expect(await restarted.resolve(ref).source == .cache) }
        print("Hosted acceptance: signed release \(refreshed.sequence), 3 native WebP decodes, offline restart cache verified.")
    }
}
