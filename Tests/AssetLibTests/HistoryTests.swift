import Foundation
import Testing
@testable import AssetLib

private func historyFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name))
}
private func historyConfig() throws -> AssetConfiguration { try .parse(historyFixture("config.json")) }
private func historyRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
private let removedNotice = "Using bundled artwork. The current release does not publish this placement."

private struct HistoryCases: Decodable {
    struct Ref: Decodable { let key: String; let width: Int; let height: Int; let rendering: String? }
    struct Case: Decodable {
        let name: String
        let releases: [String]
        let cached: [String]
        let cachedVideos: [String]
        let network: String
        let resolve: String
        let ref: Ref
        let expect: String
        let sequence: Int?
        let assetId: String?
        let assetRequests: Int
        let highestSequence: Int
    }
    let cases: [Case]
}

/// Delivery paths of every image candidate and clip a release signs, mapped to the corpus file with that hash.
private func routes(_ release: String, configuration: AssetConfiguration, files: [String: Data]) throws -> [String: Data] {
    let payload = try ManifestVerifier.verify(JSONDecoder().decode(SignedManifest.self, from: historyFixture(release)), config: configuration)
    var routes: [String: Data] = [:]
    for slot in payload.slots {
        for image in [slot] + (slot.cells ?? []).map(slot.selecting) {
            let target = AssetPixelSize(width: image.width, height: image.height)
            for candidate in ManifestVerifier.candidates(image, target: target, formats: [.webP, .png]) {
                routes[try ManifestVerifier.candidateURL(candidate, assetID: image.assetId, config: configuration).path] = files[candidate.sha256]
            }
        }
        if let video = slot.video { routes[try ManifestVerifier.videoURL(video, assetID: slot.assetId, config: configuration).path] = files[video.sha256] }
    }
    return routes
}

/// Serves the release being accepted and, online, the signed asset and clip paths. Counts every asset and clip GET.
private actor HistoryTransport: AssetTransport {
    private var manifest = Data()
    private var online = true
    private let bodies: [String: Data]
    private(set) var bodyRequests: [String] = []
    init(bodies: [String: Data]) { self.bodies = bodies }
    func set(manifest: Data) { self.manifest = manifest }
    func goOffline() { online = false }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        if url.path.hasSuffix("/manifest") { return manifest }
        bodyRequests.append(url.path)
        guard online else { throw URLError(.notConnectedToInternet) }
        guard let body = bodies[url.path], body.count <= maximumBytes else { throw AssetLibError.invalid("Not served") }
        return body
    }
}

@Suite struct HistoryTests {
    @Test func historyManifestsAreIndexedAndAccepted() throws {
        struct Index: Decodable {
            struct Entry: Decodable { let file: String; let verification: String }
            let manifests: [Entry]
        }
        let manifests = try JSONDecoder().decode(Index.self, from: historyFixture("cases.json")).manifests
        #expect(manifests.count == 149)
        let history = manifests.filter { $0.file.hasPrefix("manifests/history/") }
        #expect(history.count == 7 && history.allSatisfy { $0.verification == "accept" })
    }

    @Test func sharedHistoryResolutionCases() async throws {
        let cases = try JSONDecoder().decode(HistoryCases.self, from: historyFixture("history.json")).cases
        #expect(cases.count == 10)
        let configuration = try historyConfig()
        let assetDirectory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/assets")
        var files: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            files[hashBytes(data)] = data
        }
        for entry in cases {
            let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let storage = try FileAssetStorage(configuration: configuration, root: root)
            var cached: [String: Data] = [:], cachedVideos: [String: Data] = [:]
            for file in entry.cached {
                let data = try historyFixture(file)
                cached[hashBytes(data)] = data
                try await storage.saveAsset(data, hash: hashBytes(data))
            }
            for file in entry.cachedVideos {
                let data = try historyFixture(file)
                cachedVideos[hashBytes(data)] = data
                _ = try await storage.saveVideo(data, hash: hashBytes(data))
            }
            var bodies: [String: Data] = [:]
            for release in entry.releases { bodies.merge(try routes(release, configuration: configuration, files: files)) { _, newer in newer } }
            let current = try routes(try #require(entry.releases.last), configuration: configuration, files: files)
            let transport = HistoryTransport(bodies: bodies)
            let client = try AssetClient(configuration: configuration, storage: storage, transport: transport)
            for release in entry.releases {
                await transport.set(manifest: try historyFixture(release))
                let refreshed = await client.refresh()
                #expect(refreshed.updated && refreshed.error == nil, "\(entry.name): \(release)")
            }
            #expect(await client.sequence == entry.highestSequence, "\(entry.name)")
            if entry.network == "offline" { await transport.goOffline() } else { #expect(entry.network == "online", "\(entry.name)") }
            let state = try await storage.loadState()
            let rendering = try #require(entry.ref.rendering.map(AssetRendering.init(rawValue:)) ?? .original, "\(entry.name)")
            let reference = AssetReference(key: entry.ref.key, width: entry.ref.width, height: entry.ref.height, rendering: rendering)
            switch (entry.resolve, entry.expect) {
            case ("image", "bundled"):
                let result = await client.resolve(reference)
                #expect(result.source == .bundle && result.bytes == nil && result.sequence == nil, "\(entry.name): \(result.message)")
                #expect(result.message == removedNotice && result.armSource == .control, "\(entry.name): \(result.message)")
            case ("image", "cache"), ("image", "remote"):
                let result = await client.resolve(reference)
                #expect(result.source == (entry.expect == "cache" ? .cache : .remote), "\(entry.name): \(result.message)")
                #expect(result.sequence == entry.sequence && result.assetID == entry.assetId, "\(entry.name): \(result.message)")
                #expect(result.sha256 != nil && result.bytes.map(hashBytes) == result.sha256, "\(entry.name)")
            case ("video", "poster"):
                let video = await client.resolveVideo(reference)
                #expect(video.source == .poster && video.fileURL == nil && video.sequence == nil, "\(entry.name): \(video.message)")
            default:
                Issue.record("Unhandled shared history expectation: \(entry.resolve) \(entry.expect)")
            }
            let requests = await transport.bodyRequests
            #expect(requests.count == entry.assetRequests, "\(entry.name): \(requests)")
            // Only the latest accepted release may download; older releases are never fetched.
            #expect(requests.allSatisfy { current[$0] != nil }, "\(entry.name): \(requests)")
            // Resolution changes neither durable state nor the cache.
            #expect(try await storage.loadState() == state, "\(entry.name)")
            #expect(await client.sequence == entry.highestSequence, "\(entry.name)")
            for (hash, data) in cached { #expect(try await storage.asset(for: hash) == data, "\(entry.name)") }
            for (hash, data) in cachedVideos { #expect(try await storage.video(for: hash)?.data == data, "\(entry.name)") }
        }
    }

    /// An older release declares arms for travel.coast and the current one drops the key: a decision taken from
    /// history would call `decide`, and a resolution that walked history would return the cached control or arm b image.
    @Test func removedPlacementKeepsTheArmSourceAndSkipsTheDecision() async throws {
        let root = historyRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try historyConfig()
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        for file in ["assets/coast.webp", "assets/ridge.webp"] {
            let data = try historyFixture(file)
            try await storage.saveAsset(data, hash: hashBytes(data))
        }
        let decisions = DecisionLog()
        let transport = HistoryTransport(bodies: [:])
        let client = try AssetClient(configuration: configuration, storage: storage, transport: transport) { key, arms in
            await decisions.record(key)
            return arms.first
        }
        for release in ["manifests/valid-cells-arm-seq5.json", "manifests/history/coast-removed-seq12.json"] {
            await transport.set(manifest: try historyFixture(release))
            #expect(await client.refresh().error == nil)
        }
        let coast = AssetReference(key: "travel.coast", width: 1200, height: 900)
        let explicit = await client.resolve(coast, arm: "b")
        #expect(explicit.source == .bundle && explicit.armSource == .explicit && explicit.message == removedNotice)
        let decided = await client.resolve(coast)
        #expect(decided.source == .bundle && decided.armSource == .control && decided.message == removedNotice)
        #expect(await decisions.keys.isEmpty)
        #expect(await transport.bodyRequests.isEmpty)
    }
}

private actor DecisionLog {
    private(set) var keys: [String] = []
    func record(_ key: String) { keys.append(key) }
}
