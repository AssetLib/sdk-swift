import Foundation

public enum AssetLibError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum AssetLimits {
    public static let manifestBytes = 256 * 1024
    public static let assetBytes = 8 * 1024 * 1024
    public static let stateBytes = 3 * 1024 * 1024
    public static let cacheBytes = 50 * 1024 * 1024
    public static let cacheEntries = 100
    public static let retainedReleases = 8
    public static let decodedPixels = 16_777_216
}

public struct AssetReference: Hashable, Codable, Sendable {
    public let key: String
    public let width: Int
    public let height: Int
    public init(key: String, width: Int, height: Int) { self.key = key; self.width = width; self.height = height }
}

public struct AssetConfiguration: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let orgId: String
    public let appId: String
    public let environment: String
    public let manifestUrl: String
    public let pinnedPublicKey: String
    public let keyId: String?

    /// Accept the public JSON exported by the console. Never pass editor tokens or private keys.
    public static func parse(_ json: Data) throws -> Self {
        guard json.count <= 4096 else { throw AssetLibError.invalid("Public configuration is too large.") }
        let value = try JSONDecoder().decode(Self.self, from: json)
        try value.validate()
        return value
    }

    public func validate() throws {
        guard schemaVersion == 1, environment == "production", matches(orgId, uuidPattern), matches(appId, uuidPattern),
              pinnedPublicKey.utf8.count <= 256 else { throw AssetLibError.invalid("Invalid Assetlib public configuration.") }
        _ = try ManifestVerifier.rawPublicKey(pinnedPublicKey)
        guard keyId == nil || keyId == signingKeyID else { throw AssetLibError.invalid("Signing key ID does not match the pinned key.") }
        guard let parts = URLComponents(string: manifestUrl), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/api/delivery/\(orgId)/\(appId)/manifest", parts.url != nil else {
            throw AssetLibError.invalid("An HTTPS manifest URL scoped to this app is required.")
        }
    }

    public var signingKeyID: String { String(hashBytes(Data(pinnedPublicKey.utf8)).prefix(16)) }
    public var storageNamespace: String { hashBytes(Data("\(manifestUrl)\n\(orgId)\n\(appId)\n\(pinnedPublicKey)".utf8)) }
}

struct SignedManifest: Codable, Sendable {
    let algorithm: String
    let keyId: String
    let publicKey: String
    let payload: String
    let signature: String
}

struct ManifestPayload: Codable, Sendable {
    let schemaVersion: Int
    let orgId: String
    let appId: String
    let environment: String
    let sequence: Int
    let createdAt: String
    let slots: [ManifestSlot]
}

struct ManifestSlot: Codable, Sendable {
    let key: String
    let screen: String
    let width: Int
    let height: Int
    let assetId: String
    let sha256: String
    let url: String
    let mime: String
    let bytes: Int
}

struct PersistedState: Codable, Sendable {
    var version = 1
    var highestSequence = 0
    var history: [SignedManifest] = []
}

public enum AssetSource: String, Sendable { case bundle, cache, remote }

public struct ResolvedAsset: Sendable {
    public let source: AssetSource
    public let sequence: Int?
    public let message: String
    public let bytes: Data?
    public let sha256: String?
}

public struct RefreshResult: Sendable {
    public let updated: Bool
    public let sequence: Int
    public let error: String?
}

let uuidPattern = "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$"
let hashPattern = "^[a-f0-9]{64}$"
func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
func validReference(_ ref: AssetReference) -> Bool {
    matches(ref.key, "^[a-zA-Z][a-zA-Z0-9_.-]{0,119}$") && (1...8192).contains(ref.width) && (1...8192).contains(ref.height)
}
