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

/// Physical pixels requested by the caller; layout modifiers do not change this value.
public struct AssetPixelSize: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    var isValid: Bool { (1...8192).contains(width) && (1...8192).contains(height) }
}

/// Native formats supported by this SDK. SVG metadata is verified but never downloaded or rendered.
public enum AssetFormat: String, Sendable { case webP = "image/webp", png = "image/png" }

public enum AssetAppearance: String, Codable, Sendable { case light, dark }

/// Records the arm input; `ResolvedAsset.arm` identifies the cell actually selected.
public enum AssetArmSource: String, Codable, Sendable {
    case explicit, decision, control
    case invalidDecision = "invalid-decision"
}

public struct AssetConfiguration: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let orgId: String
    public let appId: String
    public let environment: String
    public let manifestUrl: String
    /// The explicit single pin, or the first member when the JSON supplies only `pinnedPublicKeys`.
    public let pinnedPublicKey: String
    /// Optional overlapping trust set of 1–16 distinct exact PEM strings, including any explicit single pin.
    public let pinnedPublicKeys: [String]?
    public let keyId: String?
    /// Optional derived IDs matching the trusted pins in length and order.
    public let keyIds: [String]?
    private let hasExplicitSinglePin: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion, orgId, appId, environment, manifestUrl, pinnedPublicKey, pinnedPublicKeys, keyId, keyIds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        orgId = try c.decode(String.self, forKey: .orgId)
        appId = try c.decode(String.self, forKey: .appId)
        environment = try c.decode(String.self, forKey: .environment)
        manifestUrl = try c.decode(String.self, forKey: .manifestUrl)
        // Presence plus decode rejects explicit nulls rather than treating them as omission.
        hasExplicitSinglePin = c.contains(.pinnedPublicKey)
        let single = c.contains(.pinnedPublicKey) ? try c.decode(String.self, forKey: .pinnedPublicKey) : nil
        pinnedPublicKeys = c.contains(.pinnedPublicKeys) ? try c.decode([String].self, forKey: .pinnedPublicKeys) : nil
        keyId = c.contains(.keyId) ? try c.decode(String.self, forKey: .keyId) : nil
        keyIds = c.contains(.keyIds) ? try c.decode([String].self, forKey: .keyIds) : nil
        guard keyId == nil || single != nil else {
            throw AssetLibError.invalid("Signing key ID requires an explicit single pinned public key.")
        }
        guard let primary = single ?? pinnedPublicKeys?.first else {
            throw AssetLibError.invalid("A pinned public key or key set is required.")
        }
        pinnedPublicKey = primary
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(orgId, forKey: .orgId)
        try c.encode(appId, forKey: .appId)
        try c.encode(environment, forKey: .environment)
        try c.encode(manifestUrl, forKey: .manifestUrl)
        // Do not duplicate the compatibility fallback into set-only JSON near its byte limit.
        // Preserve an explicit single pin even when it is not the first set member.
        if hasExplicitSinglePin { try c.encode(pinnedPublicKey, forKey: .pinnedPublicKey) }
        try c.encodeIfPresent(pinnedPublicKeys, forKey: .pinnedPublicKeys)
        try c.encodeIfPresent(keyId, forKey: .keyId)
        try c.encodeIfPresent(keyIds, forKey: .keyIds)
    }

    /// Accept the public JSON exported by the console. Never pass editor tokens or private keys.
    public static func parse(_ json: Data) throws -> Self {
        guard json.count <= 4096 else { throw AssetLibError.invalid("Public configuration is too large.") }
        return try JSONDecoder().decode(Self.self, from: json)
    }

    public func validate() throws {
        guard schemaVersion == 1, ["staging", "production"].contains(environment), matches(orgId, uuidPattern), matches(appId, uuidPattern),
              pinnedPublicKey.utf8.count <= 256 else { throw AssetLibError.invalid("Invalid Assetlib public configuration.") }
        guard (1...16).contains(trustedPublicKeys.count), Set(trustedPublicKeys).count == trustedPublicKeys.count,
              trustedPublicKeys.contains(pinnedPublicKey) else { throw AssetLibError.invalid("Invalid pinned public key set.") }
        for key in trustedPublicKeys {
            guard key.utf8.count <= 256 else { throw AssetLibError.invalid("Invalid pinned public key.") }
            _ = try ManifestVerifier.rawPublicKey(key)
        }
        guard keyId == nil || keyId == signingKeyID else { throw AssetLibError.invalid("Signing key ID does not match the pinned key.") }
        let derivedIDs = trustedPublicKeys.map { String(hashBytes(Data($0.utf8)).prefix(16)) }
        guard keyIds == nil || keyIds == derivedIDs else {
            throw AssetLibError.invalid("Signing key IDs do not match the pinned key set in length and order.")
        }
        let deliveryPath = "/api/delivery/\(orgId)/\(appId)"
        let environmentPath = "\(deliveryPath)/environments/\(environment)/manifest"
        guard let parts = URLComponents(string: manifestUrl), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == environmentPath || (environment == "production" && parts.percentEncodedPath == "\(deliveryPath)/manifest"),
              parts.url != nil else {
            throw AssetLibError.invalid("An HTTPS manifest URL scoped to this app is required.")
        }
    }

    public var signingKeyID: String { String(hashBytes(Data(pinnedPublicKey.utf8)).prefix(16)) }
    var trustedPublicKeys: [String] { pinnedPublicKeys ?? [pinnedPublicKey] }

    /// Durable identity survives delivery-path and signing-key changes for the same environment.
    public var storageNamespace: String {
        let parts = URLComponents(string: manifestUrl)
        let port = parts?.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
        let origin = "https://\(parts?.host?.lowercased() ?? "")\(port)"
        return hashBytes(Data("\(origin)\n\(orgId)\n\(appId)\n\(environment)".utf8))
    }

    /// The previous release used the complete URL and one pinned key. Production had two URL forms.
    var legacyStorageNamespaces: [String] {
        var urls = [manifestUrl]
        if environment == "production", var parts = URLComponents(string: manifestUrl) {
            for path in ["/api/delivery/\(orgId)/\(appId)/manifest", "/api/delivery/\(orgId)/\(appId)/environments/production/manifest"] {
                parts.percentEncodedPath = path
                if let url = parts.string { urls.append(url) }
            }
        }
        return Set(urls.flatMap { url in
            trustedPublicKeys.map { key in hashBytes(Data("\(url)\n\(orgId)\n\(appId)\n\(key)".utf8)) }
        }).sorted()
    }
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
    let renditionSchemaVersion: Int?
    let variantSchemaVersion: Int?

    enum CodingKeys: String, CodingKey { case schemaVersion, orgId, appId, environment, sequence, createdAt, slots, renditionSchemaVersion, variantSchemaVersion }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        orgId = try c.decode(String.self, forKey: .orgId)
        appId = try c.decode(String.self, forKey: .appId)
        environment = try c.decode(String.self, forKey: .environment)
        sequence = try c.decode(Int.self, forKey: .sequence)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        slots = try c.decode([ManifestSlot].self, forKey: .slots)
        // Null is not absence: malformed extensions must fail closed.
        renditionSchemaVersion = c.contains(.renditionSchemaVersion) ? try c.decode(Int.self, forKey: .renditionSchemaVersion) : nil
        variantSchemaVersion = c.contains(.variantSchemaVersion) ? try c.decode(Int.self, forKey: .variantSchemaVersion) : nil
    }
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
    let renditions: [ManifestRendition]?
    let accessibility: AssetAccessibility?
    let variants: ManifestVariants?
    let cells: [ManifestCell]?

    enum CodingKeys: String, CodingKey { case key, screen, width, height, assetId, sha256, url, mime, bytes, renditions, accessibility, variants, cells }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        screen = try c.decode(String.self, forKey: .screen)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        assetId = try c.decode(String.self, forKey: .assetId)
        sha256 = try c.decode(String.self, forKey: .sha256)
        url = try c.decode(String.self, forKey: .url)
        mime = try c.decode(String.self, forKey: .mime)
        bytes = try c.decode(Int.self, forKey: .bytes)
        renditions = c.contains(.renditions) ? try c.decode([ManifestRendition].self, forKey: .renditions) : nil
        accessibility = c.contains(.accessibility) ? try c.decode(AssetAccessibility.self, forKey: .accessibility) : nil
        variants = c.contains(.variants) ? try c.decode(ManifestVariants.self, forKey: .variants) : nil
        cells = c.contains(.cells) ? try c.decode([ManifestCell].self, forKey: .cells) : nil
    }

    /// Project a selected cell onto its placement so image validation and rendition selection stay shared.
    func selecting(_ cell: ManifestCell) -> ManifestSlot { ManifestSlot(placement: self, cell: cell) }

    private init(placement: ManifestSlot, cell: ManifestCell) {
        key = placement.key; screen = placement.screen; width = placement.width; height = placement.height
        assetId = cell.assetId; sha256 = cell.sha256; url = cell.url; mime = cell.mime; bytes = cell.bytes
        renditions = cell.renditions; accessibility = cell.accessibility
        variants = nil; cells = nil
    }
}

struct ManifestVariants: Codable, Sendable {
    let appearance: [AssetAppearance]?
    let arm: [String]?

    enum CodingKeys: String, CodingKey { case appearance, arm }
    private struct AxisKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let axes = try decoder.container(keyedBy: AxisKey.self)
        guard axes.allKeys.allSatisfy({ CodingKeys(rawValue: $0.stringValue) != nil }) else {
            throw AssetLibError.invalid("Unsupported variant axis.")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = c.contains(.appearance) ? try c.decode([AssetAppearance].self, forKey: .appearance) : nil
        arm = c.contains(.arm) ? try c.decode([String].self, forKey: .arm) : nil
    }
}

struct ManifestCell: Codable, Sendable {
    let appearance: AssetAppearance?
    let arm: String?
    let assetId: String
    let sha256: String
    let url: String
    let mime: String
    let bytes: Int
    let renditions: [ManifestRendition]?
    let accessibility: AssetAccessibility?

    // Native clients deliberately ignore states, defaultState, and other unknown keys.
    enum CodingKeys: String, CodingKey { case appearance, arm, assetId, sha256, url, mime, bytes, renditions, accessibility }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = c.contains(.appearance) ? try c.decode(AssetAppearance.self, forKey: .appearance) : nil
        arm = c.contains(.arm) ? try c.decode(String.self, forKey: .arm) : nil
        assetId = try c.decode(String.self, forKey: .assetId)
        sha256 = try c.decode(String.self, forKey: .sha256)
        url = try c.decode(String.self, forKey: .url)
        mime = try c.decode(String.self, forKey: .mime)
        bytes = try c.decode(Int.self, forKey: .bytes)
        renditions = c.contains(.renditions) ? try c.decode([ManifestRendition].self, forKey: .renditions) : nil
        accessibility = c.contains(.accessibility) ? try c.decode(AssetAccessibility.self, forKey: .accessibility) : nil
    }
}

struct ManifestRendition: Codable, Sendable {
    let sha256: String
    let url: String
    let mime: String
    let bytes: Int
    let width: Int
    let height: Int
}

struct AssetCandidate: Sendable {
    let sha256: String
    let url: String
    let mime: String
    let bytes: Int
    let width: Int
    let height: Int
    let isLegacy: Bool
    init(_ slot: ManifestSlot) {
        sha256 = slot.sha256; url = slot.url; mime = slot.mime; bytes = slot.bytes
        width = slot.width; height = slot.height; isLegacy = true
    }
    init(_ rendition: ManifestRendition) {
        sha256 = rendition.sha256; url = rendition.url; mime = rendition.mime; bytes = rendition.bytes
        width = rendition.width; height = rendition.height; isLegacy = false
    }
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
    public let assetID: String?
    public let mime: String?
    public let pixelSize: AssetPixelSize?
    /// Describes these bytes from this release; never borrowed from a newer release or the bundle.
    public let accessibility: AssetAccessibility?
    /// The selected cell's appearance, or nil for appearance-independent artwork.
    public let appearance: AssetAppearance?
    /// The selected cell's arm, or nil for control artwork.
    public let arm: String?
    public let armSource: AssetArmSource
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
