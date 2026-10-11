import Foundation
import AVFoundation
import CryptoKit
import Testing
@testable import AssetLib

private func videoFixture(_ name: String) throws -> Data { try Data(contentsOf: videoFixtureURL(name)) }
private func videoFixtureURL(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
}
private func videoRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private let coastPlacement = AssetReference(key: "travel.coast", width: 1200, height: 900)
private let assetPath = "/api/delivery/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/assets/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private func clipPath(_ hash: String) -> String { assetPath + "/videos/" + hash }

/// The corpus configuration with its manifest on `host`. The host is not signed, so stubbed tests can keep routes apart.
private func videoConfig(host: String = "fixtures.assetlib.example", pinnedPublicKey: String? = nil) throws -> AssetConfiguration {
    var object = try JSONSerialization.jsonObject(with: videoFixture("config.json")) as! [String: Any]
    var parts = URLComponents(string: object["manifestUrl"] as! String)!
    parts.host = host
    object["manifestUrl"] = parts.string!
    if let pinnedPublicKey { object["pinnedPublicKey"] = pinnedPublicKey; object.removeValue(forKey: "keyId") }
    return try .parse(JSONSerialization.data(withJSONObject: object))
}

private struct VideoCases: Decodable {
    struct Descriptor: Decodable {
        let format: String, profile: String, mime: String, sha256: String, url: String
        let bytes: Int, width: Int, height: Int, durationMs: Int
        let frameRate: Double
    }
    struct Case: Decodable { let manifest: String; let expect: String; let sha256: String?; let reason: String? }
    struct ByteFailure: Decodable { let manifest: String; let body: String; let reason: String }
    let file: String
    let descriptor: Descriptor
    let cases: [Case]
    let byteFailures: [ByteFailure]
}

private struct ManifestIndex: Decodable {
    struct Entry: Decodable { let file: String; let verification: String }
    let manifests: [Entry]
}

private struct Request: Sendable { let path: String; let accept: String; let maximumBytes: Int }

private actor VideoTransport: AssetTransport {
    private var manifest: Data
    private var bodies: [String: Data]
    private var online = true
    private(set) var requests: [Request] = []
    init(manifest: Data, bodies: [String: Data] = [:]) { self.manifest = manifest; self.bodies = bodies }
    func set(manifest: Data) { self.manifest = manifest }
    func serve(_ body: Data, at path: String) { bodies[path] = body }
    func goOffline() { online = false }
    var clipRequests: [Request] { requests.filter { $0.path.contains("/videos/") } }
    func get(_ url: URL, maximumBytes: Int, accept: String) throws -> Data {
        guard online else { throw AssetLibError.invalid("Offline") }
        if url.path.hasSuffix("/manifest") { return manifest }
        requests.append(Request(path: url.path, accept: accept, maximumBytes: maximumBytes))
        guard let body = bodies[url.path], body.count <= maximumBytes else { throw AssetLibError.invalid("Not served") }
        return body
    }
}

/// A storage that keeps bytes in memory, so it can never hand a player a file.
private actor MemoryStorage: AssetStorage {
    var state: Data?
    var assets: [String: Data] = [:]
    func loadState() -> Data? { state }
    func saveState(_ data: Data) { state = data }
    func asset(for hash: String) -> Data? { assets[hash] }
    func saveAsset(_ data: Data, hash: String) { assets[hash] = data }
}

/// Synthetic releases around the corpus clip, signed with a deterministic TEST ONLY key.
private struct SignedVideos {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x56, count: 32))
    let configuration: AssetConfiguration
    let original: [String: Any]
    init() throws {
        let prefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00])
        let pem = "-----BEGIN PUBLIC KEY-----\n" + (prefix + key.publicKey.rawRepresentation).base64EncodedString() + "\n-----END PUBLIC KEY-----\n"
        configuration = try videoConfig(pinnedPublicKey: pem)
        let envelope = try JSONDecoder().decode(SignedManifest.self, from: videoFixture("manifests/valid-video-seq9.json"))
        original = try JSONSerialization.jsonObject(with: Data(envelope.payload.utf8)) as! [String: Any]
    }
    var clip: [String: Any] { (original["slots"] as! [[String: Any]])[0]["video"] as! [String: Any] }
    /// A clip whose bytes are never served.
    var unavailableClip: [String: Any] {
        var clip = self.clip
        clip["sha256"] = String(repeating: "ab", count: 32)
        clip["url"] = clipPath(String(repeating: "ab", count: 32))
        return clip
    }
    /// `clip: nil` publishes the placement as poster only; another `placement` key leaves it out.
    func manifest(sequence: Int, clip: [String: Any]?, placement: String = "travel.coast") throws -> Data {
        var payload = original
        var slot = (original["slots"] as! [[String: Any]])[0]
        slot["video"] = clip
        slot["key"] = placement
        payload["sequence"] = sequence
        payload["slots"] = [slot]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        return try JSONEncoder().encode(SignedManifest(algorithm: "Ed25519", keyId: configuration.signingKeyID,
            publicKey: configuration.pinnedPublicKey, payload: text, signature: key.signature(for: Data(text.utf8)).base64EncodedString()))
    }
}

/// Serves stubbed HTTPS responses per host to `HTTPSAssetTransport`, in chunks and after an optional delay.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var contentType: String
        var body: Data
        var delay: TimeInterval = 0
        var contentLength = true
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [String: Response]] = [:]
    nonisolated(unsafe) private static var accepts: [String: [String]] = [:]
    static func serve(host: String, _ routes: [String: Response]) { lock.withLock { self.routes[host] = routes } }
    static func accepts(host: String) -> [String] { lock.withLock { accepts[host] ?? [] } }

    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        guard let url = request.url, let host = url.host else { return }
        let response = Self.lock.withLock { () -> Response? in
            Self.accepts[host, default: []].append(request.value(forHTTPHeaderField: "Accept") ?? "")
            return Self.routes[host]?[url.path]
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
            guard !stateLock.withLock({ stopped }) else { return }
            var headers = ["Content-Type": response.contentType]
            if response.contentLength { headers["Content-Length"] = String(response.body.count) }
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < response.body.count {
                let end = min(offset + 10_000, response.body.count)
                client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

private func stubbedTransport(timeout: TimeInterval = 8, videoTimeout: TimeInterval = 30) throws -> HTTPSAssetTransport {
    try HTTPSAssetTransport(timeout: timeout, videoTimeout: videoTimeout, protocolClasses: [StubProtocol.self])
}
private func uniqueHost() -> String { "t\(UUID().uuidString.lowercased().prefix(8)).assetlib.example" }

@Suite struct VideoTests {
    @Test func sharedVideoManifestCases() throws {
        let index = try JSONDecoder().decode(ManifestIndex.self, from: videoFixture("cases.json"))
        let video = index.manifests.filter { $0.file.contains("video") }
        #expect(video.count == 27 && video.filter { $0.verification == "reject" }.count == 25)
        let configuration = try videoConfig()
        for entry in video {
            let envelope = try JSONDecoder().decode(SignedManifest.self, from: videoFixture(entry.file))
            if entry.verification == "accept" {
                let payload = try ManifestVerifier.verify(envelope, config: configuration)
                #expect(payload.videoSchemaVersion == 1 && payload.slots[0].video != nil, "\(entry.file)")
            } else {
                #expect(entry.verification == "reject")
                #expect(throws: AssetLibError.self, "\(entry.file)") { _ = try ManifestVerifier.verify(envelope, config: configuration) }
            }
        }
        let cases = try JSONDecoder().decode(VideoCases.self, from: videoFixture("video.json"))
        let envelope = try JSONDecoder().decode(SignedManifest.self, from: videoFixture("manifests/valid-video-seq9.json"))
        let decoded = try #require(try ManifestVerifier.verify(envelope, config: configuration).slots[0].video)
        let expected = cases.descriptor
        #expect(decoded.format == expected.format && decoded.profile == expected.profile && decoded.mime == expected.mime)
        #expect(decoded.sha256 == expected.sha256 && decoded.url == expected.url && decoded.bytes == expected.bytes)
        #expect(decoded.width == expected.width && decoded.height == expected.height)
        #expect(decoded.durationMs == expected.durationMs && decoded.frameRate == expected.frameRate)
        #expect(hashBytes(try videoFixture(cases.file)) == expected.sha256)
    }

    @Test func sharedVideoResolutionCases() async throws {
        let cases = try JSONDecoder().decode(VideoCases.self, from: videoFixture("video.json"))
        let assets = try FileManager.default.contentsOfDirectory(at: videoFixtureURL("assets"), includingPropertiesForKeys: nil)
        var bodies: [String: Data] = [:]
        for file in assets { let data = try Data(contentsOf: file); bodies[clipPath(hashBytes(data))] = data }
        #expect(cases.cases.count == 2)
        for entry in cases.cases {
            let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let configuration = try videoConfig()
            let transport = VideoTransport(manifest: try videoFixture(entry.manifest), bodies: bodies)
            let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
            #expect(await client.refresh().sequence == 9)
            let video = await client.resolveVideo(coastPlacement)
            let requests = await transport.clipRequests
            #expect(requests.count == 1 && requests[0].accept == "video/mp4", "\(entry.manifest)")
            let namespace = root.appendingPathComponent(configuration.storageNamespace)
            if entry.expect == "video" {
                let sha = try #require(entry.sha256)
                let url = try #require(video.fileURL)
                #expect(video.source == .remote && video.sequence == 9)
                #expect(url.isFileURL && url.lastPathComponent == "\(sha).mp4")
                #expect(url.deletingLastPathComponent().path == namespace.path)
                #expect(hashBytes(try Data(contentsOf: url)) == sha)
                #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
                #expect(video.width == 320 && video.height == 240 && video.duration == .milliseconds(2000) && video.frameRate == 30)
                #expect(requests[0].maximumBytes == cases.descriptor.bytes)
                let cached = await client.resolveVideo(coastPlacement)
                #expect(cached.source == .cache && cached.fileURL == url && cached.sequence == 9)
                // A cached file over the read bound is a miss, and the clip downloads again over it.
                try Data(count: AssetLimits.videoBytes + 1).write(to: url)
                let repaired = await client.resolveVideo(coastPlacement)
                #expect(repaired.source == .remote)
                #expect(hashBytes(try Data(contentsOf: url)) == sha)
                await transport.goOffline()
                let restarted = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
                let offline = await restarted.resolveVideo(coastPlacement)
                #expect(offline.source == .cache && offline.fileURL == url)
                #expect(await transport.clipRequests.count == 2)
            } else {
                #expect(entry.expect == "poster" && entry.reason == "header")
                #expect(video.source == .poster && video.fileURL == nil && video.sequence == nil && video.duration == nil)
                // Length and SHA-256 match the signed descriptor; only the header check rejects these bytes.
                let envelope = try JSONDecoder().decode(SignedManifest.self, from: videoFixture(entry.manifest))
                let descriptor = try #require(try ManifestVerifier.verify(envelope, config: configuration).slots[0].video)
                let served = try #require(bodies[clipPath(descriptor.sha256)])
                #expect(served.count == descriptor.bytes && hashBytes(served) == descriptor.sha256)
                #expect(!MP4Header.check(served, width: descriptor.width, height: descriptor.height))
                let stored = try FileManager.default.contentsOfDirectory(atPath: namespace.path).filter { $0.hasSuffix(".mp4") }
                #expect(stored.isEmpty)
            }
        }
    }

    @Test func byteFailuresReturnThePoster() async throws {
        let cases = try JSONDecoder().decode(VideoCases.self, from: videoFixture("video.json"))
        #expect(cases.byteFailures.count == 2)
        for failure in cases.byteFailures {
            let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let configuration = try videoConfig()
            let transport = VideoTransport(manifest: try videoFixture(failure.manifest),
                                           bodies: [clipPath(cases.descriptor.sha256): try videoFixture(failure.body)])
            let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
            _ = await client.refresh()
            let video = await client.resolveVideo(coastPlacement)
            #expect(video.source == .poster && video.fileURL == nil, "\(failure.reason)")
            #expect(await transport.clipRequests.count == 1, "\(failure.reason)")
            let namespace = root.appendingPathComponent(configuration.storageNamespace)
            #expect(try FileManager.default.contentsOfDirectory(atPath: namespace.path).filter { $0.hasSuffix(".mp4") }.isEmpty)
        }
    }

    @Test func olderReleasesAreCacheOnly() async throws {
        let signed = try SignedVideos()
        let configuration = signed.configuration
        let loop = try videoFixture("assets/loop.mp4")
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = VideoTransport(manifest: try signed.manifest(sequence: 9, clip: signed.clip), bodies: [clipPath(hashBytes(loop)): loop])
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        #expect(await client.refresh().sequence == 9)
        // Release 9's clip was never cached, and release 10's clip is unavailable: no request for release 9's clip.
        await transport.set(manifest: try signed.manifest(sequence: 10, clip: signed.unavailableClip))
        #expect(await client.refresh().sequence == 10)
        #expect(await client.resolveVideo(coastPlacement).source == .poster)
        #expect(await transport.clipRequests.map(\.path) == [signed.unavailableClip["url"] as! String])
    }

    @Test func unusableCurrentClipFallsBackToTheNewestCachedOlderClip() async throws {
        let signed = try SignedVideos()
        let configuration = signed.configuration
        let loop = try videoFixture("assets/loop.mp4")
        let hash = hashBytes(loop)
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = VideoTransport(manifest: try signed.manifest(sequence: 9, clip: signed.clip), bodies: [clipPath(hash): loop])
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        _ = await client.refresh()
        #expect(await client.resolveVideo(coastPlacement).source == .remote)
        // Release 10 has no clip, and release 11's new clip cannot download while offline.
        await transport.set(manifest: try signed.manifest(sequence: 10, clip: nil))
        _ = await client.refresh()
        await transport.set(manifest: try signed.manifest(sequence: 11, clip: signed.unavailableClip))
        #expect(await client.refresh().sequence == 11)
        await transport.goOffline()
        let fallback = await client.resolveVideo(coastPlacement)
        #expect(fallback.source == .cache && fallback.sequence == 9 && fallback.fileURL?.lastPathComponent == "\(hash).mp4")
        #expect(fallback.message.contains("release 9"))
        #expect(await transport.clipRequests.map(\.path) == [clipPath(hash)])
    }

    @Test func currentReleaseWithoutAClipShowsThePoster() async throws {
        let signed = try SignedVideos()
        let configuration = signed.configuration
        let loop = try videoFixture("assets/loop.mp4")
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = VideoTransport(manifest: try signed.manifest(sequence: 9, clip: signed.clip), bodies: [clipPath(hashBytes(loop)): loop])
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        _ = await client.refresh()
        #expect(await client.resolveVideo(coastPlacement).source == .remote)
        // Publishing the placement without a clip (as a rollback can) shows the poster despite the cached clip.
        await transport.set(manifest: try signed.manifest(sequence: 10, clip: nil))
        #expect(await client.refresh().sequence == 10)
        let posterOnly = await client.resolveVideo(coastPlacement)
        #expect(posterOnly.source == .poster && posterOnly.fileURL == nil && posterOnly.message.contains("no clip"))
        // So does a current release that leaves the placement out.
        await transport.set(manifest: try signed.manifest(sequence: 11, clip: signed.clip, placement: "travel.ridge"))
        #expect(await client.refresh().sequence == 11)
        #expect(await client.resolveVideo(coastPlacement).source == .poster)
        #expect(await transport.clipRequests.count == 1)
    }

    @Test func imageResolutionNeverDownloadsAClipAndOtherStoragesGetThePoster() async throws {
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try videoConfig()
        let loop = try videoFixture("assets/loop.mp4")
        let transport = VideoTransport(manifest: try videoFixture("manifests/valid-video-seq9.json"),
                                       bodies: [assetPath: try videoFixture("assets/coast.webp"), clipPath(hashBytes(loop)): loop])
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        _ = await client.refresh()
        let image = await client.resolve(coastPlacement)
        #expect(image.source == .remote && image.mime == "image/webp")
        #expect(await transport.requests.map(\.path) == [assetPath])

        let memory = try AssetClient(configuration: configuration, storage: MemoryStorage(), transport: transport)
        _ = await memory.refresh()
        let video = await memory.resolveVideo(coastPlacement)
        #expect(video.source == .poster && video.fileURL == nil)
        #expect(await transport.clipRequests.isEmpty)
    }

    @Test func clipsShareTheCacheBudget() async throws {
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try videoConfig()
        let storage = try FileAssetStorage(configuration: configuration, root: root)
        for index in 0..<AssetLimits.cacheEntries {
            let data = Data("entry \(index)".utf8)
            try await storage.saveAsset(data, hash: hashBytes(data))
        }
        let loop = try videoFixture("assets/loop.mp4")
        let url = try await storage.saveVideo(loop, hash: hashBytes(loop))
        let namespace = root.appendingPathComponent(configuration.storageNamespace)
        let entries = try FileManager.default.contentsOfDirectory(atPath: namespace.path).filter { $0.hasSuffix(".asset") || $0.hasSuffix(".mp4") }
        #expect(entries.count == AssetLimits.cacheEntries && entries.contains(url.lastPathComponent))
        let cached = try #require(try await storage.video(for: hashBytes(loop)))
        #expect(cached.url == url && cached.data == loop)
        await #expect(throws: AssetLibError.self) { try await storage.saveVideo(loop, hash: String(repeating: "0", count: 64)) }
    }

    @Test func cachedClipLoadsInAVFoundation() async throws {
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try videoConfig()
        let loop = try videoFixture("assets/loop.mp4")
        let transport = VideoTransport(manifest: try videoFixture("manifests/valid-video-seq9.json"), bodies: [clipPath(hashBytes(loop)): loop])
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        _ = await client.refresh()
        _ = await client.resolveVideo(coastPlacement)
        let cached = await client.resolveVideo(coastPlacement)
        #expect(cached.source == .cache)
        let asset = AVURLAsset(url: try #require(cached.fileURL))
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 2.0) < 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let size = try await tracks[0].load(.naturalSize)
        #expect(size.width == 320 && size.height == 240)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func headerCheckRules() throws {
        let loop = try videoFixture("assets/loop.mp4")
        func offset(of type: String, in data: Data, after start: Int = 0) -> Int {
            data.range(of: Data(type.utf8), in: start..<data.count)!.lowerBound - 4
        }
        func box(_ data: Data, _ type: String) -> Data {
            let start = offset(of: type, in: data)
            let size = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            return data.subdata(in: start..<start + size)
        }
        #expect(MP4Header.check(loop, width: 320, height: 240))
        #expect(!MP4Header.check(loop, width: 322, height: 240))
        #expect(!MP4Header.check(loop, width: 320, height: 180))
        let ftyp = box(loop, "ftyp"), moov = box(loop, "moov"), mdat = box(loop, "mdat")
        #expect(MP4Header.check(ftyp + moov + mdat, width: 320, height: 240))
        #expect(!MP4Header.check(ftyp + mdat + moov, width: 320, height: 240))
        #expect(!MP4Header.check(moov + ftyp + mdat, width: 320, height: 240))
        #expect(!MP4Header.check(loop + Data([0, 0, 0, 8]) + Data("moof".utf8), width: 320, height: 240))
        // The first "avc1" is a compatible brand in ftyp; the sample entry follows stsd.
        let entry = offset(of: "avc1", in: loop, after: offset(of: "stsd", in: loop))
        var hevc = loop
        hevc.replaceSubrange(entry + 4..<entry + 8, with: Data("hvc1".utf8))
        #expect(!MP4Header.check(hevc, width: 320, height: 240))
        var oversized = loop
        let moovStart = offset(of: "moov", in: loop)
        oversized.replaceSubrange(moovStart..<moovStart + 4, with: Data([0, 0x10, 0, 0]))
        #expect(!MP4Header.check(oversized, width: 320, height: 240))
        #expect(!MP4Header.check(try videoFixture("assets/coast.webp"), width: 320, height: 240))
        #expect(!MP4Header.check(Data(), width: 320, height: 240))
    }

    @Test func videoDeadlineIsSeparateFromTheImageDeadline() async throws {
        let defaults = try HTTPSAssetTransport()
        #expect(defaults.deadline(accept: "video/mp4") == 30 && defaults.deadline(accept: "image/webp") == 8)
        for invalid in [0, 0.01, 30.5, .nan, .infinity] as [TimeInterval] {
            #expect(throws: AssetLibError.self) { _ = try HTTPSAssetTransport(videoTimeout: invalid) }
        }
        let host = uniqueHost()
        let loop = try videoFixture("assets/loop.mp4")
        let image = try videoFixture("assets/coast.webp")
        StubProtocol.serve(host: host, ["/clip": .init(contentType: "video/mp4", body: loop, delay: 0.6),
                                        "/image": .init(contentType: "image/webp", body: image, delay: 0.6)])
        let clipURL = URL(string: "https://\(host)/clip")!, imageURL = URL(string: "https://\(host)/image")!

        let shortImage = try stubbedTransport(timeout: 0.15, videoTimeout: 5)
        #expect(try await shortImage.get(clipURL, maximumBytes: loop.count, accept: "video/mp4") == loop)
        await #expect(throws: (any Error).self) { _ = try await shortImage.get(imageURL, maximumBytes: image.count, accept: "image/webp") }

        let shortVideo = try stubbedTransport(timeout: 5, videoTimeout: 0.15)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await shortVideo.get(clipURL, maximumBytes: loop.count, accept: "video/mp4") }
        #expect(ContinuousClock.now - started < .seconds(0.55))
        #expect(try await shortVideo.get(imageURL, maximumBytes: image.count, accept: "image/webp") == image)
        #expect(StubProtocol.accepts(host: host) == ["video/mp4", "image/webp", "video/mp4", "image/webp"])
    }

    @Test func stalledClipReturnsThePosterAtTheVideoDeadline() async throws {
        let host = uniqueHost()
        let configuration = try videoConfig(host: host)
        let loop = try videoFixture("assets/loop.mp4")
        StubProtocol.serve(host: host, [
            URLComponents(string: configuration.manifestUrl)!.path: .init(contentType: "application/json", body: try videoFixture("manifests/valid-video-seq9.json")),
            clipPath(hashBytes(loop)): .init(contentType: "video/mp4", body: loop, delay: 3),
        ])
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root),
                                     transport: stubbedTransport(videoTimeout: 0.2))
        #expect(await client.refresh().sequence == 9)
        let started = ContinuousClock.now
        let video = await client.resolveVideo(coastPlacement)
        #expect(video.source == .poster && ContinuousClock.now - started < .seconds(2))
    }

    @Test func chunkedAppendsKeepTheByteBounds() async throws {
        let host = uniqueHost()
        let large = Data((0..<200_003).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        StubProtocol.serve(host: host, [
            "/large": .init(contentType: "video/mp4", body: large),
            "/unannounced": .init(contentType: "video/mp4", body: large, contentLength: false),
            "/announced": .init(contentType: "video/mp4", body: large),
            "/image": .init(contentType: "image/webp", body: large),
        ])
        let transport = try stubbedTransport()
        let url = { (path: String) in URL(string: "https://\(host)\(path)")! }
        // Exactly the limit passes intact across chunk boundaries; one byte over fails while streaming or on Content-Length.
        #expect(try await transport.get(url("/large"), maximumBytes: large.count, accept: "video/mp4") == large)
        await #expect(throws: AssetLibError.invalid("Delivery exceeds its byte limit.")) {
            _ = try await transport.get(url("/unannounced"), maximumBytes: large.count - 1, accept: "video/mp4")
        }
        await #expect(throws: AssetLibError.invalid("Delivery exceeds its byte limit.")) {
            _ = try await transport.get(url("/announced"), maximumBytes: large.count - 1, accept: "video/mp4")
        }
        // The Accept value must match the response type, and the per-request cap depends on it.
        await #expect(throws: AssetLibError.self) { _ = try await transport.get(url("/image"), maximumBytes: large.count, accept: "video/mp4") }
        await #expect(throws: AssetLibError.invalid("Unsafe delivery request.")) {
            _ = try await transport.get(url("/large"), maximumBytes: AssetLimits.videoBytes + 1, accept: "video/mp4")
        }
        #expect(try await transport.get(url("/image"), maximumBytes: AssetLimits.assetBytes, accept: "image/webp") == large)
    }
}

@MainActor @Suite struct LoopingVideoTests {
    private let clip = videoFixtureURL("assets/loop.mp4")

    private func playingModels(_ count: Int, slots: LoopingVideoSlots) -> [LoopingVideoModel] {
        (0..<count).map { _ in
            let model = LoopingVideoModel(slots: slots, reduceMotion: false)
            model.show(clip, for: coastPlacement)
            model.visible = true
            return model
        }
    }

    @Test func atMostTwoClipsPlayAndWaitingViewsArePromoted() {
        let slots = LoopingVideoSlots(capacity: 2)
        let models = playingModels(3, slots: slots)
        #expect(models.map(\.isPlaying) == [true, true, false])
        #expect(models[0].player != nil && models[2].player == nil && models[2].showsPoster)
        #expect(slots.playingCount == 2)
        models[0].visible = false
        #expect(!models[0].isPlaying && models[0].player == nil)
        #expect(models[2].isPlaying && models[2].player != nil && slots.playingCount == 2)
        models[0].visible = true
        #expect(!models[0].isPlaying && models[0].showsPoster)
        models[1].foreground = false
        #expect(!models[1].isPlaying && models[0].isPlaying && slots.playingCount == 2)
    }

    @Test func reducedMotionErrorsAndFirstFrameShowThePoster() {
        let slots = LoopingVideoSlots(capacity: 2)
        let models = playingModels(3, slots: slots)
        let first = models[0]
        #expect(first.isPlaying && first.player?.isMuted == true && first.showsPoster)
        first.firstFrameRendered()
        #expect(!first.showsPoster)
        first.reduceMotion = true
        #expect(!first.isPlaying && first.showsPoster && first.player == nil)
        #expect(models[2].isPlaying && slots.playingCount == 2)
        models[1].playbackFailed()
        #expect(!models[1].isPlaying && models[1].showsPoster && models[1].player == nil && slots.playingCount == 1)
        first.reduceMotion = false
        #expect(first.isPlaying && first.showsPoster && slots.playingCount == 2)
        first.show(nil, for: coastPlacement)
        #expect(!first.isPlaying && first.showsPoster && slots.playingCount == 1)
    }

    @Test func reducedMotionSkipsTheClipDownload() async throws {
        let root = try videoRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try videoConfig()
        let loop = try videoFixture("assets/loop.mp4")
        let transport = VideoTransport(manifest: try videoFixture("manifests/valid-video-seq9.json"), bodies: [clipPath(hashBytes(loop)): loop])
        let client = try AssetClient(configuration: configuration, storage: FileAssetStorage(configuration: configuration, root: root), transport: transport)
        _ = await client.refresh()
        let model = LoopingVideoModel(slots: LoopingVideoSlots(capacity: 2), reduceMotion: true)
        model.visible = true
        await model.load(client: client, reference: coastPlacement)
        #expect(model.clip == nil && model.showsPoster)
        #expect(await transport.clipRequests.isEmpty)
        model.reduceMotion = false
        await model.load(client: client, reference: coastPlacement)
        #expect(model.clip?.lastPathComponent == "\(hashBytes(loop)).mp4" && model.isPlaying)
        #expect(await transport.clipRequests.count == 1)
    }
}
