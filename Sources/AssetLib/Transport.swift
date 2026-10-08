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

public struct HTTPSAssetTransport: AssetTransport {
    private let timeout: TimeInterval
    public init(timeout: TimeInterval = 8) throws {
        guard timeout.isFinite, (0.02...30).contains(timeout) else { throw AssetLibError.invalid("Timeout must be between 0.02 and 30 seconds.") }
        self.timeout = timeout
    }
    public func get(_ url: URL, maximumBytes: Int, accept: String) async throws -> Data {
        guard url.scheme == "https", maximumBytes > 0, maximumBytes <= AssetLimits.assetBytes else { throw AssetLibError.invalid("Unsafe delivery request.") }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await fetch(url, maximumBytes: maximumBytes, accept: accept) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AssetLibError.invalid("Assetlib request timed out.")
            }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw CancellationError() }
            return data
        }
    }
    private func fetch(_ url: URL, maximumBytes: Int, accept: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), http.url == url,
              http.mimeType?.lowercased() == accept else { throw AssetLibError.invalid("Delivery status, redirect, or content type was rejected.") }
        if let length = http.value(forHTTPHeaderField: "Content-Length") {
            guard matches(length, "^[0-9]+$"), let size = Int(length), size <= maximumBytes else { throw AssetLibError.invalid("Delivery exceeds its byte limit.") }
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw AssetLibError.invalid("Delivery exceeds its byte limit.") }
            data.append(byte)
        }
        return data
    }
}
