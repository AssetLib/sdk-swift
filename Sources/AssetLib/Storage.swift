import Foundation
import Darwin

public protocol AssetStorage: Sendable {
    func loadState() async throws -> Data?
    /// Durable atomic commit. Reject lower sequences and conflicting payloads at an equal sequence.
    func saveState(_ data: Data) async throws
    func asset(for hash: String) async throws -> Data?
    func saveAsset(_ data: Data, hash: String) async throws
}

/// App-private, bounded disk storage. The namespace includes the origin, app, organization, and pinned key.
public actor FileAssetStorage: AssetStorage {
    private let directory: URL
    private let configuration: AssetConfiguration
    private let files = FileManager.default
    public init(configuration: AssetConfiguration, root: URL? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Assetlib", isDirectory: true)
        directory = base.appendingPathComponent(configuration.storageNamespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    public func loadState() throws -> Data? { try boundedRead(directory.appendingPathComponent("state.json"), limit: AssetLimits.stateBytes) }
    public func saveState(_ data: Data) throws {
        guard data.count <= AssetLimits.stateBytes else { throw AssetLibError.invalid("Release state exceeds its storage limit.") }
        let next = try ManifestVerifier.verifiedState(data, config: configuration)
        // An advisory OS lock protects atomic read-check-write across storage instances and app processes.
        let descriptor = open(directory.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AssetLibError.invalid("Unable to lock release state.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AssetLibError.invalid("Unable to lock release state.") }
        defer { flock(descriptor, LOCK_UN) }
        if let oldData = try loadState() {
            let old = try ManifestVerifier.verifiedState(oldData, config: configuration)
            guard next.highestSequence >= old.highestSequence else { throw AssetLibError.invalid("Stored release sequence is newer.") }
            if next.highestSequence == old.highestSequence {
                guard Data(next.history[0].payload.utf8) == Data(old.history[0].payload.utf8) else { throw AssetLibError.invalid("Conflicting content reused a stored release sequence.") }
                return
            }
        }
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
    public func asset(for hash: String) throws -> Data? {
        guard matches(hash, hashPattern) else { throw AssetLibError.invalid("Invalid cache key.") }
        return try boundedRead(directory.appendingPathComponent(hash + ".webp"), limit: AssetLimits.assetBytes)
    }
    public func saveAsset(_ data: Data, hash: String) throws {
        guard matches(hash, hashPattern), data.count <= AssetLimits.assetBytes, hashBytes(data) == hash else { throw AssetLibError.invalid("Invalid cache entry.") }
        let descriptor = open(directory.appendingPathComponent("cache.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AssetLibError.invalid("Unable to lock asset cache.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AssetLibError.invalid("Unable to lock asset cache.") }
        defer { flock(descriptor, LOCK_UN) }
        try data.write(to: directory.appendingPathComponent(hash + ".webp"), options: .atomic)
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "webp" }
            .map { url -> (URL, Int, Date) in
                let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where count > AssetLimits.cacheEntries || bytes > AssetLimits.cacheBytes {
            try files.removeItem(at: entry.0)
            count -= 1
            bytes -= entry.1
        }
    }
    private func boundedRead(_ url: URL, limit: Int) throws -> Data? {
        guard files.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= limit else { throw AssetLibError.invalid("Stored file exceeds its bound or is invalid.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw AssetLibError.invalid("Stored file exceeds its bound.") }
        return data
    }
}
