import Foundation
import CryptoKit
import ImageIO

public func hashBytes(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

enum ManifestVerifier {
    static func rawPublicKey(_ pem: String) throws -> Data {
        guard matches(pem, "^-----BEGIN PUBLIC KEY-----\\r?\\n([A-Za-z0-9+/=\\r\\n]+)-----END PUBLIC KEY-----\\r?\\n?$"),
              let start = pem.range(of: "-----BEGIN PUBLIC KEY-----"), let end = pem.range(of: "-----END PUBLIC KEY-----") else {
            throw AssetLibError.invalid("Expected an Ed25519 SPKI PEM public key.")
        }
        let base64 = pem[start.upperBound..<end.lowerBound].replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let prefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x03,0x21,0x00])
        guard let der = Data(base64Encoded: base64), der.count == 44, der.prefix(12) == prefix else {
            throw AssetLibError.invalid("The pinned key must be Ed25519 SPKI.")
        }
        return der.dropFirst(12)
    }

    static func verify(_ envelope: SignedManifest, config: AssetConfiguration) throws -> ManifestPayload {
        guard envelope.algorithm == "Ed25519", envelope.publicKey == config.pinnedPublicKey, envelope.keyId == config.signingKeyID,
              envelope.payload.utf8.count <= AssetLimits.manifestBytes, matches(envelope.signature, "^[A-Za-z0-9+/]{86}==$"),
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else {
            throw AssetLibError.invalid("Invalid signed manifest envelope.")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey(config.pinnedPublicKey))
        guard key.isValidSignature(signature, for: Data(envelope.payload.utf8)) else { throw AssetLibError.invalid("Manifest signature verification failed.") }
        let payload = try JSONDecoder().decode(ManifestPayload.self, from: Data(envelope.payload.utf8))
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = date.date(from: payload.createdAt)
        date.formatOptions = [.withInternetDateTime]
        guard payload.schemaVersion == 1, payload.orgId == config.orgId, payload.appId == config.appId,
              payload.environment == config.environment, (1...2_147_483_647).contains(payload.sequence),
              fractional != nil || date.date(from: payload.createdAt) != nil, (1...100).contains(payload.slots.count) else {
            throw AssetLibError.invalid("Unsupported or cross-app manifest payload.")
        }
        var keys = Set<String>()
        for slot in payload.slots {
            guard validReference(.init(key: slot.key, width: slot.width, height: slot.height)), keys.insert(slot.key).inserted,
                  slot.screen.utf16.count <= 120, matches(slot.assetId, uuidPattern), matches(slot.sha256, hashPattern),
                  slot.mime == "image/webp", (1...AssetLimits.assetBytes).contains(slot.bytes) else {
                throw AssetLibError.invalid("Invalid or unsupported placement in manifest.")
            }
            _ = try assetURL(slot, config: config)
        }
        return payload
    }

    static func verifiedState(_ data: Data, config: AssetConfiguration) throws -> PersistedState {
        guard data.count <= AssetLimits.stateBytes else { throw AssetLibError.invalid("Stored state exceeds its bound.") }
        let state = try JSONDecoder().decode(PersistedState.self, from: data)
        guard state.version == 1, (1...2_147_483_647).contains(state.highestSequence), (1...AssetLimits.retainedReleases).contains(state.history.count) else { throw AssetLibError.invalid("Invalid stored release state.") }
        var previous = state.highestSequence + 1
        for envelope in state.history {
            let payload = try verify(envelope, config: config)
            guard payload.sequence < previous else { throw AssetLibError.invalid("Invalid stored release order.") }
            previous = payload.sequence
        }
        guard try verify(state.history[0], config: config).sequence == state.highestSequence else { throw AssetLibError.invalid("Stored sequence does not match its signature.") }
        return state
    }

    static func assetURL(_ slot: ManifestSlot, config: AssetConfiguration) throws -> URL {
        guard let base = URL(string: config.manifestUrl), let baseParts = URLComponents(url: base, resolvingAgainstBaseURL: true),
              let url = URL(string: slot.url, relativeTo: base)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), parts.scheme == baseParts.scheme,
              parts.host?.lowercased() == baseParts.host?.lowercased(), (parts.port ?? 443) == (baseParts.port ?? 443),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/api/delivery/\(config.orgId)/\(config.appId)/assets/\(slot.assetId)" else {
            throw AssetLibError.invalid("Asset URL is outside the configured app.")
        }
        return url
    }

    static func validAsset(_ data: Data, slot: ManifestSlot) -> Bool {
        guard data.count == slot.bytes, data.count <= AssetLimits.assetBytes, hashBytes(data) == slot.sha256,
              data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= AssetLimits.decodedPixels,
              width * slot.height == height * slot.width,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else { return false }
        return true
    }
}
