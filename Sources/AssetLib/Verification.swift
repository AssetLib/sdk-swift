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
        guard envelope.algorithm == "Ed25519", config.trustedPublicKeys.contains(envelope.publicKey),
              envelope.keyId == String(hashBytes(Data(envelope.publicKey.utf8)).prefix(16)),
              envelope.payload.utf8.count <= AssetLimits.manifestBytes, matches(envelope.signature, "^[A-Za-z0-9+/]{86}==$"),
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else {
            throw AssetLibError.invalid("Invalid signed manifest envelope.")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey(envelope.publicKey))
        guard key.isValidSignature(signature, for: Data(envelope.payload.utf8)) else { throw AssetLibError.invalid("Manifest signature verification failed.") }
        let payload: ManifestPayload
        do {
            payload = try JSONDecoder().decode(ManifestPayload.self, from: Data(envelope.payload.utf8))
        } catch {
            throw AssetLibError.invalid("Invalid manifest payload: \(error.localizedDescription)")
        }
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = date.date(from: payload.createdAt)
        date.formatOptions = [.withInternetDateTime]
        guard payload.schemaVersion == 1, payload.orgId == config.orgId, payload.appId == config.appId,
              payload.environment == config.environment, (1...2_147_483_647).contains(payload.sequence),
              fractional != nil || date.date(from: payload.createdAt) != nil, (1...100).contains(payload.slots.count),
              payload.renditionSchemaVersion == nil || payload.renditionSchemaVersion == 1,
              payload.variantSchemaVersion == nil || payload.variantSchemaVersion == 1 else {
            throw AssetLibError.invalid("Unsupported or cross-app manifest payload.")
        }
        var keys = Set<String>()
        for slot in payload.slots {
            guard validReference(.init(key: slot.key, width: slot.width, height: slot.height)), keys.insert(slot.key).inserted,
                  slot.screen.utf16.count <= 120 else {
                throw AssetLibError.invalid("Invalid or unsupported placement in manifest.")
            }
            try validateImage(slot, renditionSchemaVersion: payload.renditionSchemaVersion, config: config)
            try validateVariants(slot, variantSchemaVersion: payload.variantSchemaVersion,
                                 renditionSchemaVersion: payload.renditionSchemaVersion, config: config)
        }
        return payload
    }

    private static func validateImage(_ slot: ManifestSlot, renditionSchemaVersion: Int?, config: AssetConfiguration) throws {
        guard matches(slot.assetId, uuidPattern), matches(slot.sha256, hashPattern),
              slot.mime == "image/webp", (1...AssetLimits.assetBytes).contains(slot.bytes),
              slot.rendering.map({ matches($0, "^[a-z][a-z0-9-]{0,31}\\z") }) ?? true else {
            throw AssetLibError.invalid("Invalid or unsupported image descriptor in manifest.")
        }
        _ = try assetURL(slot, config: config)
        if let renditions = slot.renditions {
            guard renditionSchemaVersion == 1, (1...7).contains(renditions.count) else {
                throw AssetLibError.invalid("Unsupported rendition extension or count.")
            }
            var hashes = Set<String>()
            for rendition in renditions {
                let ratio = Double(slot.width) / Double(slot.height)
                guard matches(rendition.sha256, hashPattern), hashes.insert(rendition.sha256).inserted,
                      ["image/webp", "image/png", "image/svg+xml"].contains(rendition.mime),
                      (1...AssetLimits.assetBytes).contains(rendition.bytes),
                      rendition.mime != "image/svg+xml" || rendition.bytes <= 262_144,
                      (1...8192).contains(rendition.width), (1...8192).contains(rendition.height),
                      rendition.width * rendition.height <= AssetLimits.decodedPixels,
                      abs(Double(rendition.width) / Double(rendition.height) - ratio) / ratio <= 0.02 else {
                    throw AssetLibError.invalid("Invalid rendition metadata.")
                }
                _ = try candidateURL(AssetCandidate(rendition), assetID: slot.assetId, config: config)
            }
        }
    }

    private static func validateVariants(_ slot: ManifestSlot, variantSchemaVersion: Int?, renditionSchemaVersion: Int?, config: AssetConfiguration) throws {
        guard let variants = slot.variants else {
            guard slot.cells == nil else { throw AssetLibError.invalid("Variant cells require declared variants.") }
            return
        }
        guard variantSchemaVersion == 1, variants.appearance != nil || variants.arm != nil else {
            throw AssetLibError.invalid("Unsupported or empty variant axes.")
        }
        if let appearances = variants.appearance {
            guard (1...2).contains(appearances.count), Set(appearances).count == appearances.count else {
                throw AssetLibError.invalid("Invalid appearance variants.")
            }
        }
        if let arms = variants.arm {
            let reserved = ["control", "any", "constructor", "prototype", "__proto__"]
            guard (1...4).contains(arms.count), Set(arms).count == arms.count,
                  arms.allSatisfy({ matches($0, "^[a-z][a-z0-9_-]{0,19}\\z") && !reserved.contains($0) }) else {
                throw AssetLibError.invalid("Invalid arm variants.")
            }
        }
        guard let cells = slot.cells else { return }
        let appearances = variants.appearance ?? [], arms = variants.arm ?? []
        guard cells.count <= (arms.count + 1) * (appearances.count + 1) - 1 else {
            throw AssetLibError.invalid("Invalid variant cell count.")
        }
        var coordinates = Set<String>()
        for cell in cells {
            guard cell.appearance != nil || cell.arm != nil,
                  cell.appearance.map(appearances.contains) ?? true,
                  cell.arm.map(arms.contains) ?? true,
                  coordinates.insert("\(cell.arm ?? "control")/\(cell.appearance?.rawValue ?? "any")").inserted else {
                throw AssetLibError.invalid("Invalid or duplicate variant cell coordinates.")
            }
            try validateImage(slot.selecting(cell), renditionSchemaVersion: renditionSchemaVersion, config: config)
        }
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
        try candidateURL(AssetCandidate(slot), assetID: slot.assetId, config: config)
    }

    static func candidateURL(_ candidate: AssetCandidate, assetID: String, config: AssetConfiguration) throws -> URL {
        let path = "/api/delivery/\(config.orgId)/\(config.appId)/assets/\(assetID)" + (candidate.isLegacy ? "" : "/renditions/\(candidate.sha256)")
        guard let base = URL(string: config.manifestUrl), let baseParts = URLComponents(url: base, resolvingAgainstBaseURL: true),
              let url = URL(string: candidate.url, relativeTo: base)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true), parts.scheme == baseParts.scheme,
              parts.host?.lowercased() == baseParts.host?.lowercased(), (parts.port ?? 443) == (baseParts.port ?? 443),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == path else {
            throw AssetLibError.invalid("Asset URL is outside the configured app.")
        }
        return url
    }

    static func validAsset(_ data: Data, slot: ManifestSlot) -> Bool {
        decodedSize(data, candidate: AssetCandidate(slot)) != nil
    }

    static func decodedSize(_ data: Data, candidate: AssetCandidate) -> AssetPixelSize? {
        let knownType: Bool
        switch candidate.mime {
        case "image/webp": knownType = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8)
        case "image/png": knownType = data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
        default: knownType = false
        }
        guard knownType, data.count == candidate.bytes, data.count <= AssetLimits.assetBytes, hashBytes(data) == candidate.sha256,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= AssetLimits.decodedPixels,
              candidate.isLegacy ? width * candidate.height == height * candidate.width : (width == candidate.width && height == candidate.height),
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else { return nil }
        return .init(width: width, height: height)
    }

    static func candidates(_ slot: ManifestSlot, target: AssetPixelSize, formats: [AssetFormat]) -> [AssetCandidate] {
        let supported = Set(formats.map(\.rawValue))
        let rasters = (slot.renditions ?? []).filter { supported.contains($0.mime) }.map(AssetCandidate.init)
        let ordered = rasters.sorted { a, b in
            let aFits = a.width >= target.width && a.height >= target.height
            let bFits = b.width >= target.width && b.height >= target.height
            if aFits != bFits { return aFits }
            let aArea = a.width * a.height, bArea = b.width * b.height
            if aArea != bArea { return aFits ? aArea < bArea : aArea > bArea }
            if a.bytes != b.bytes { return a.bytes < b.bytes }
            return a.sha256 < b.sha256
        }
        return ordered + [AssetCandidate(slot)]
    }
}
