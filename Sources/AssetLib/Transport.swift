import Foundation

/// Injectable transport for deterministic tests. Implementations must enforce the byte limit before buffering a response.
public protocol AssetTransport: Sendable {
    func get(_ url: URL, maximumBytes: Int, accept: String) async throws -> Data
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Test seam: URL protocol classes placed ahead of the system ones. Classes are immutable metadata.
private struct ProtocolClasses: @unchecked Sendable { let classes: [AnyClass] }

public struct HTTPSAssetTransport: AssetTransport {
    private let timeout: TimeInterval
    private let videoTimeout: TimeInterval
    private let protocolClasses: ProtocolClasses

    /// `timeout` bounds manifest and image transfers; `videoTimeout` bounds `video/mp4` clip transfers. Each is 0.02–30 seconds.
    public init(timeout: TimeInterval = 8, videoTimeout: TimeInterval = 30) throws {
        try self.init(timeout: timeout, videoTimeout: videoTimeout, protocolClasses: [])
    }
    init(timeout: TimeInterval, videoTimeout: TimeInterval, protocolClasses: [AnyClass]) throws {
        guard timeout.isFinite, (0.02...30).contains(timeout) else { throw AssetLibError.invalid("Timeout must be between 0.02 and 30 seconds.") }
        guard videoTimeout.isFinite, (0.02...30).contains(videoTimeout) else { throw AssetLibError.invalid("Video timeout must be between 0.02 and 30 seconds.") }
        self.timeout = timeout
        self.videoTimeout = videoTimeout
        self.protocolClasses = ProtocolClasses(classes: protocolClasses)
    }
    func deadline(accept: String) -> TimeInterval { accept == "video/mp4" ? videoTimeout : timeout }

    public func get(_ url: URL, maximumBytes: Int, accept: String) async throws -> Data {
        let cap = accept == "video/mp4" ? AssetLimits.videoBytes : AssetLimits.assetBytes
        guard url.scheme == "https", maximumBytes > 0, maximumBytes <= cap else { throw AssetLibError.invalid("Unsafe delivery request.") }
        let deadline = deadline(accept: accept)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await fetch(url, maximumBytes: maximumBytes, accept: accept, deadline: deadline) }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw AssetLibError.invalid("Assetlib request timed out.")
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
    }
    private func fetch(_ url: URL, maximumBytes: Int, accept: String, deadline: TimeInterval) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        if !protocolClasses.classes.isEmpty { configuration.protocolClasses = protocolClasses.classes + (configuration.protocolClasses ?? []) }
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: deadline)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), http.url == url,
              http.mimeType?.lowercased() == accept else { throw AssetLibError.invalid("Delivery status, redirect, or content type was rejected.") }
        if let length = http.value(forHTTPHeaderField: "Content-Length") {
            guard matches(length, "^[0-9]+$"), let size = Int(length), size <= maximumBytes else { throw AssetLibError.invalid("Delivery exceeds its byte limit.") }
        }
        // The limit is checked per byte, so no more than maximumBytes is ever held; appends and cancellation checks are per chunk.
        let chunkSize = 64 * 1024
        var data = Data()
        data.reserveCapacity(min(maximumBytes, chunkSize))
        var chunk: [UInt8] = []
        chunk.reserveCapacity(min(maximumBytes, chunkSize))
        for try await byte in stream {
            guard data.count + chunk.count < maximumBytes else { throw AssetLibError.invalid("Delivery exceeds its byte limit.") }
            chunk.append(byte)
            if chunk.count == chunkSize {
                try Task.checkCancellation()
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        data.append(contentsOf: chunk)
        return data
    }
}
