import Foundation
import CryptoKit
import Testing
@testable import AssetLib

private func identityFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
}

private struct IdentityFixtures {
    // TEST ONLY: a second key exercises an overlapping key rotation.
    let secondKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x53, count: 32))
    var secondPEM: String {
        let prefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00])
        return "-----BEGIN PUBLIC KEY-----\n" + (prefix + secondKey.publicKey.rawRepresentation).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
    }
    func configuration(scoped: Bool = false, expanded: Bool = false, rotated: Bool = false,
                       environment: String = "production", origin: String = "https://fixtures.assetlib.example") throws -> AssetConfiguration {
        var object = try JSONSerialization.jsonObject(with: identityFixture("config.json")) as! [String: Any]
        let firstPEM = object["pinnedPublicKey"] as! String
        object["environment"] = environment
        object["manifestUrl"] = origin + "/api/delivery/\(object["orgId"]!)/\(object["appId"]!)" +
            ((scoped || environment != "production") ? "/environments/\(environment)/manifest" : "/manifest")
        if expanded { object["pinnedPublicKeys"] = [firstPEM, secondPEM] }
        if rotated { object["pinnedPublicKey"] = secondPEM; object.removeValue(forKey: "keyId") }
        return try .parse(JSONSerialization.data(withJSONObject: object))
    }
    func secondManifest(sequence: Int) throws -> Data {
        let original = try JSONDecoder().decode(SignedManifest.self, from: identityFixture("manifests/valid-rollback-seq3.json"))
        var payload = try JSONSerialization.jsonObject(with: Data(original.payload.utf8)) as! [String: Any]
        payload["sequence"] = sequence
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        return try JSONEncoder().encode(SignedManifest(algorithm: "Ed25519", keyId: String(hashBytes(Data(secondPEM.utf8)).prefix(16)),
            publicKey: secondPEM, payload: String(decoding: bytes, as: UTF8.self), signature: secondKey.signature(for: bytes).base64EncodedString()))
    }
}

private actor IdentityTransport: AssetTransport {
    var manifest: Data
    init(_ manifest: Data) { self.manifest = manifest }
    func set(_ manifest: Data) { self.manifest = manifest }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        let data = try url.path.hasSuffix("/manifest") ? manifest : identityFixture("assets/coast.webp")
        guard data.count <= maximumBytes else { throw AssetLibError.invalid("Fixture exceeds response limit.") }
        return data
    }
}

private let identityCoast = AssetReference(key: "travel.coast", width: 1200, height: 900)
private func legacyIdentity(_ configuration: AssetConfiguration) -> String {
    hashBytes(Data("\(configuration.manifestUrl)\n\(configuration.orgId)\n\(configuration.appId)\n\(configuration.pinnedPublicKey)".utf8))
}
private func seedLegacy(_ configuration: AssetConfiguration, root: URL, state: Data, cacheExtension: String = "asset") throws -> URL {
    let directory = root.appendingPathComponent(legacyIdentity(configuration), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try state.write(to: directory.appendingPathComponent("state.json"))
    let cache = try identityFixture("assets/coast.webp")
    try cache.write(to: directory.appendingPathComponent(hashBytes(cache) + "." + cacheExtension))
    return directory
}

@Suite struct StorageIdentityTests {
    @Test func namespaceUsesOnlyCanonicalOriginOrganizationAppAndEnvironment() throws {
        let f = IdentityFixtures(), original = try f.configuration()
        let expected = hashBytes(Data("https://fixtures.assetlib.example\n\(original.orgId)\n\(original.appId)\nproduction".utf8))
        #expect(original.storageNamespace == expected)
        #expect(try f.configuration(scoped: true).storageNamespace == expected)
        #expect(try f.configuration(expanded: true, rotated: true).storageNamespace == expected)
        #expect(try f.configuration(origin: "https://FIXTURES.assetlib.example:443").storageNamespace == expected)
        #expect(try f.configuration(environment: "staging").storageNamespace != expected)
        #expect(try f.configuration(origin: "https://fixtures.assetlib.example:8443").storageNamespace != expected)
        #expect(try f.configuration(origin: "https://different.assetlib.example").storageNamespace != expected)
    }

    @Test func expandedAndRotatedKeysKeepReplayFloorAndCache() async throws {
        let f = IdentityFixtures(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try f.configuration()
        let transport = IdentityTransport(try identityFixture("manifests/valid-rollback-seq3.json"))
        let first = try AssetClient(configuration: original, storage: FileAssetStorage(configuration: original, root: root), transport: transport)
        #expect(await first.refresh().sequence == 3)
        let cached = await first.resolve(identityCoast)
        #expect(cached.source == .remote)
        for rotated in [false, true] {
            let next = try f.configuration(expanded: true, rotated: rotated)
            await transport.set(try identityFixture("manifests/valid-seq1.json"))
            let client = try AssetClient(configuration: next, storage: FileAssetStorage(configuration: next, root: root), transport: transport)
            #expect(await client.initialize().sequence == 3)
            let stale = await client.refresh()
            #expect(stale.sequence == 3 && stale.error != nil && !stale.updated)
            let resolved = await client.resolve(identityCoast, download: false)
            #expect(resolved.source == .cache && resolved.sha256 == cached.sha256)
        }
        let expanded = try f.configuration(expanded: true)
        let client = try AssetClient(configuration: expanded, storage: FileAssetStorage(configuration: expanded, root: root), transport: transport)
        await transport.set(try f.secondManifest(sequence: 4))
        #expect(await client.refresh().sequence == 4)
        #expect(await client.resolve(identityCoast, download: false).source == .cache)
        let restarted = try AssetClient(configuration: expanded, storage: FileAssetStorage(configuration: expanded, root: root), transport: transport)
        #expect(await restarted.initialize().sequence == 4)
    }

    @Test func productionURLSwitchKeepsReplayFloorAndCache() async throws {
        let f = IdentityFixtures(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try f.configuration(), scoped = try f.configuration(scoped: true)
        let transport = IdentityTransport(try identityFixture("manifests/valid-rollback-seq3.json"))
        let first = try AssetClient(configuration: original, storage: FileAssetStorage(configuration: original, root: root), transport: transport)
        #expect(await first.refresh().sequence == 3)
        #expect(await first.resolve(identityCoast).source == .remote)
        await transport.set(try identityFixture("manifests/valid-seq1.json"))
        let restarted = try AssetClient(configuration: scoped, storage: FileAssetStorage(configuration: scoped, root: root), transport: transport)
        #expect(await restarted.initialize().sequence == 3)
        let replay = await restarted.refresh()
        #expect(replay.sequence == 3 && replay.error != nil)
        #expect(await restarted.resolve(identityCoast, download: false).source == .cache)
    }

    @Test func productionAndStagingRemainIsolated() async throws {
        let f = IdentityFixtures(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let production = try f.configuration(), staging = try f.configuration(environment: "staging")
        let transport = IdentityTransport(try identityFixture("manifests/valid-rollback-seq3.json"))
        let first = try AssetClient(configuration: production, storage: FileAssetStorage(configuration: production, root: root), transport: transport)
        #expect(await first.refresh().sequence == 3)
        #expect(await first.resolve(identityCoast).source == .remote)
        let client = try AssetClient(configuration: staging, storage: FileAssetStorage(configuration: staging, root: root), transport: transport)
        #expect(await client.initialize().sequence == 0)
        #expect(await client.resolve(identityCoast, download: false).source == .bundle)
        await transport.set(try identityFixture("manifests/valid-staging-seq1.json"))
        #expect(await client.refresh().sequence == 1)
        #expect(await first.initialize().sequence == 3)
    }

    @Test(arguments: ["asset", "webp"])
    func verifiedLegacyStateAndCacheMigrateAcrossURLAndKeyRotation(cacheExtension: String) async throws {
        let f = IdentityFixtures(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try f.configuration(), next = try f.configuration(scoped: true, expanded: true, rotated: true)
        let state = try identityFixture("state/after-rollback-seq3.json")
        let legacy = try seedLegacy(original, root: root, state: state, cacheExtension: cacheExtension)
        let client = try AssetClient(configuration: next, storage: FileAssetStorage(configuration: next, root: root), transport: IdentityTransport(try identityFixture("manifests/valid-seq1.json")))
        #expect(await client.initialize().sequence == 3)
        #expect(await client.resolve(identityCoast, download: false).source == .cache)
        #expect(await client.refresh().error != nil)
        #expect(try Data(contentsOf: root.appendingPathComponent(next.storageNamespace).appendingPathComponent("state.json")) == state)
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("state.json").path))
    }

    @Test func unverifiedLegacyStateIsIgnoredAndPreserved() async throws {
        let f = IdentityFixtures(), configuration = try f.configuration()
        for data in [Data("{invalid".utf8), try identityFixture("state/corrupt-highest.json")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let legacy = try seedLegacy(configuration, root: root, state: data)
            let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: IdentityTransport(try identityFixture("manifests/valid-seq1.json")))
            let initial = await client.initialize()
            #expect(initial.sequence == 0 && initial.error == nil)
            #expect(await client.resolve(identityCoast, download: false).source == .bundle)
            #expect(try Data(contentsOf: legacy.appendingPathComponent("state.json")) == data)
            #expect(await client.refresh().sequence == 1)
        }
    }

    @Test func migratedNamespaceNeverReadsLegacyStateAgainEvenAfterStateDeletion() async throws {
        let f = IdentityFixtures(), configuration = try f.configuration(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try identityFixture("state/after-rollback-seq3.json")
        let legacy = try seedLegacy(configuration, root: root, state: state)
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        #expect(try await storage.loadState() == state)
        // An older application can recreate its legacy directory after migration.
        let newerEnvelope = try JSONDecoder().decode(SignedManifest.self, from: identityFixture("manifests/valid-renditions-seq4.json"))
        let recreated = try JSONEncoder().encode(PersistedState(highestSequence: 4, history: [newerEnvelope]))
        try recreated.write(to: legacy.appendingPathComponent("state.json"))
        #expect(try await FileAssetStorage(configuration: configuration, root: root).loadState() == state)
        let current = root.appendingPathComponent(configuration.storageNamespace).appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: current)
        let restarted = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: IdentityTransport(try identityFixture("manifests/valid-seq1.json")))
        let initial = await restarted.initialize()
        #expect(initial.sequence == 0 && initial.error != nil)
        #expect(await restarted.resolve(identityCoast, download: false).source == .bundle)
        #expect(await restarted.refresh().error != nil)
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(try Data(contentsOf: legacy.appendingPathComponent("state.json")) == recreated)
    }

    @Test func migrationAndConcurrentCommitCannotRegressState() async throws {
        let f = IdentityFixtures(), configuration = try f.configuration(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try seedLegacy(configuration, root: root, state: identityFixture("state/after-seq2.json"))
        let migrating = try FileAssetStorage(configuration: configuration, root: root)
        let writing = try FileAssetStorage(configuration: configuration, root: root)
        let next = try identityFixture("state/after-rollback-seq3.json")
        async let loaded = migrating.loadState()
        async let saved: Void = writing.saveState(next)
        _ = try await (loaded, saved)
        #expect(try await migrating.loadState() == next)
    }

    @Test func migrationKeepsExistingCacheWithinItsEntryBound() async throws {
        let f = IdentityFixtures(), configuration = try f.configuration(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try seedLegacy(configuration, root: root, state: identityFixture("state/after-rollback-seq3.json"))
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        for byte in 0..<AssetLimits.cacheEntries {
            let data = Data([UInt8(byte)])
            try await storage.saveAsset(data, hash: hashBytes(data))
        }
        _ = try await storage.loadState()
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(configuration.storageNamespace), includingPropertiesForKeys: nil)
            .filter { ["asset", "webp"].contains($0.pathExtension) }
        #expect(entries.count <= AssetLimits.cacheEntries)
        #expect(try await storage.asset(for: hashBytes(identityFixture("assets/coast.webp"))) != nil)
    }

    @Test func revokingARequiredHistoricalKeyPreservesStateAndFailsClosed() async throws {
        let f = IdentityFixtures(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try f.configuration(), revoked = try f.configuration(rotated: true)
        let storage = try FileAssetStorage(configuration: original, root: root)
        let state = try identityFixture("state/after-rollback-seq3.json")
        try await storage.saveState(state)
        let client = try AssetClient(configuration: revoked, storage: FileAssetStorage(configuration: revoked, root: root), transport: IdentityTransport(try f.secondManifest(sequence: 1)))
        #expect(await client.initialize().error != nil)
        #expect(await client.refresh().error != nil)
        #expect(await client.resolve(identityCoast, download: false).source == .bundle)
        #expect(try await storage.loadState() == state)
    }
}
