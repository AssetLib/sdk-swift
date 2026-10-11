import Foundation

/// Where a resolved clip came from. `.poster` means no clip: show the placement's resolved image or bundled fallback.
public enum AssetVideoSource: String, Sendable { case remote, cache, poster }

/// A verified short looping clip stored as a local file, or the poster outcome.
public struct AssetVideo: Sendable {
    /// A local `.mp4` whose length, SHA-256 and header were verified. Nil for the poster outcome.
    public let fileURL: URL?
    public let width: Int?
    public let height: Int?
    public let duration: Duration?
    public let frameRate: Double?
    public let source: AssetVideoSource
    /// The release that supplied the clip; nil for the poster outcome.
    public let sequence: Int?
    public let message: String
}

/// The signed `video` descriptor of a base slot (`videoSchemaVersion: 1`).
struct ManifestVideo: Codable, Sendable {
    let format: String
    let profile: String
    let mime: String
    let sha256: String
    let url: String
    let bytes: Int
    let width: Int
    let height: Int
    let durationMs: Int
    let frameRate: Double
}

extension ManifestVerifier {
    static func validateVideo(_ slot: ManifestSlot, videoSchemaVersion: Int?, config: AssetConfiguration) throws {
        if slot.cells?.contains(where: \.hasVideo) == true { throw AssetLibError.invalid("Variant cells cannot carry a video.") }
        guard let video = slot.video else { return }
        guard videoSchemaVersion == 1, !slot.hasAnimation else {
            throw AssetLibError.invalid("A video requires videoSchemaVersion 1 and excludes an animation.")
        }
        guard video.format == "mp4", video.profile == "h264-loop-v1", video.mime == "video/mp4",
              matches(video.sha256, hashPattern), (1...AssetLimits.videoBytes).contains(video.bytes),
              video.width % 2 == 0, video.height % 2 == 0, (16...1280).contains(video.width), (16...1280).contains(video.height),
              video.width * video.height <= 921_600, video.width * slot.height == video.height * slot.width,
              (1_000...10_000).contains(video.durationMs), video.frameRate.isFinite, (1...30).contains(video.frameRate) else {
            throw AssetLibError.invalid("Invalid or unsupported video descriptor in manifest.")
        }
        _ = try videoURL(video, assetID: slot.assetId, config: config)
    }

    static func videoURL(_ video: ManifestVideo, assetID: String, config: AssetConfiguration) throws -> URL {
        try deliveryURL(video.url, path: "/api/delivery/\(config.orgId)/\(config.appId)/assets/\(assetID)/videos/\(video.sha256)", config: config)
    }

    /// Length and SHA-256 first, then the bounded header check. Never decodes frames.
    static func verifiedVideo(_ data: Data, video: ManifestVideo) -> Bool {
        data.count == video.bytes && data.count <= AssetLimits.videoBytes && hashBytes(data) == video.sha256
            && MP4Header.check(data, width: video.width, height: video.height)
    }
}

/// A bounded ISO BMFF box walk: `ftyp` first, `moov` before the first `mdat`, no `moof`, and an `avc1`
/// sample entry with the signed width and height. The console validates the full envelope before signing.
enum MP4Header {
    private static let maximumBoxes = 4_096
    private static let maximumSampleEntries = 16

    private struct Box {
        let type: String
        let start: Int
        let end: Int
        let contentStart: Int
    }

    static func check(_ data: Data, width: Int, height: Int) -> Bool {
        let bytes = [UInt8](data)
        var budget = maximumBoxes
        guard let top = boxes(bytes, from: 0, to: bytes.count, topLevel: true, budget: &budget),
              top.first?.type == "ftyp", !top.contains(where: { $0.type == "moof" }),
              let moovIndex = top.firstIndex(where: { $0.type == "moov" }) else { return false }
        if let mdatIndex = top.firstIndex(where: { $0.type == "mdat" }), mdatIndex < moovIndex { return false }
        let moov = top[moovIndex]
        guard let traks = children(bytes, of: moov, named: "trak", budget: &budget) else { return false }
        for trak in traks {
            var stsd = trak
            for name in ["mdia", "minf", "stbl", "stsd"] {
                guard let next = children(bytes, of: stsd, named: name, budget: &budget)?.first else { return false }
                stsd = next
            }
            // FullBox header (4 bytes), then a 32-bit entry count.
            guard stsd.contentStart + 8 <= stsd.end else { return false }
            let count = Int(uint32(bytes, stsd.contentStart + 4))
            guard count <= maximumSampleEntries,
                  let entries = boxes(bytes, from: stsd.contentStart + 8, to: stsd.end, topLevel: false, budget: &budget),
                  entries.count == count else { return false }
            // VisualSampleEntry: 8 reserved and reference bytes, 16 predefined bytes, then 16-bit width and height.
            for entry in entries where entry.type == "avc1" && entry.contentStart + 28 <= entry.end {
                if Int(uint16(bytes, entry.contentStart + 24)) == width, Int(uint16(bytes, entry.contentStart + 26)) == height {
                    return true
                }
            }
        }
        return false
    }

    private static func children(_ bytes: [UInt8], of parent: Box, named type: String, budget: inout Int) -> [Box]? {
        boxes(bytes, from: parent.contentStart, to: parent.end, topLevel: false, budget: &budget)?.filter { $0.type == type }
    }

    /// Splits a range into boxes. Every box must fit inside the range; size 0 (to end) is allowed only at the top level.
    private static func boxes(_ bytes: [UInt8], from start: Int, to end: Int, topLevel: Bool, budget: inout Int) -> [Box]? {
        var result: [Box] = []
        var offset = start
        while offset < end {
            guard end - offset >= 8, budget > 0 else { return nil }
            budget -= 1
            var size = Int(uint32(bytes, offset))
            var header = 8
            if size == 1 {
                guard end - offset >= 16 else { return nil }
                let large = uint64(bytes, offset + 8)
                guard large <= UInt64(end - offset) else { return nil }
                size = Int(large)
                header = 16
            } else if size == 0 {
                guard topLevel else { return nil }
                size = end - offset
            }
            guard size >= header, size <= end - offset else { return nil }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(Box(type: type, start: offset, end: offset + size, contentStart: offset + header))
            offset += size
        }
        return result
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }
    private static func uint64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }
}
