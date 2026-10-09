import Foundation
import Darwin

public protocol AssetStorage: Sendable {
    func loadState() async throws -> Data?
    /// Durable atomic commit. Reject lower sequences and conflicting payloads at an equal sequence.
    func saveState(_ data: Data) async throws
    func asset(for hash: String) async throws -> Data?
    func saveAsset(_ data: Data, hash: String) async throws
}

/// App-private, bounded disk storage, isolated by origin, organization, app, and environment.
public actor FileAssetStorage: AssetStorage {
    private let directory: URL
    private let legacyDirectories: [URL]
    private let configuration: AssetConfiguration
    private let files = FileManager.default
    public init(configuration: AssetConfiguration, root: URL? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Assetlib", isDirectory: true)
        directory = base.appendingPathComponent(configuration.storageNamespace, isDirectory: true)
        legacyDirectories = configuration.legacyStorageNamespaces.map { base.appendingPathComponent($0, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    public func loadState() throws -> Data? {
        let descriptor = try lock(directory.appendingPathComponent("state.lock"))
        defer { unlock(descriptor) }
        return try loadStateLocked()
    }
    public func saveState(_ data: Data) throws {
        guard data.count <= AssetLimits.stateBytes else { throw AssetLibError.invalid("Release state exceeds its storage limit.") }
        let next = try ManifestVerifier.verifiedState(data, config: configuration)
        // An advisory OS lock protects atomic read-check-write across storage instances and app processes.
        let descriptor = try lock(directory.appendingPathComponent("state.lock"))
        defer { unlock(descriptor) }
        if let oldData = try loadStateLocked() {
            let old = try ManifestVerifier.verifiedState(oldData, config: configuration)
            guard next.highestSequence >= old.highestSequence else { throw AssetLibError.invalid("Stored release sequence is newer.") }
            if next.highestSequence == old.highestSequence {
                guard Data(next.history[0].payload.utf8) == Data(old.history[0].payload.utf8) else { throw AssetLibError.invalid("Conflicting content reused a stored release sequence.") }
                return
            }
        }
        try markNamespaceUsed()
        try data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    /// All migration and state commits share this namespace's OS lock across instances/processes.
    private func loadStateLocked() throws -> Data? {
        if let data = try boundedRead(directory.appendingPathComponent("state.json"), limit: AssetLimits.stateBytes) {
            try markNamespaceUsed()
            return data
        }
        guard !files.fileExists(atPath: directory.appendingPathComponent("namespace-v2").path) else {
            // A missing state after use is corruption, never permission to lower the replay floor.
            throw AssetLibError.invalid("Persisted release state disappeared.")
        }
        var descriptors: [Int32] = []
        defer { descriptors.reversed().forEach(unlock) }
        var verified: [(directory: URL, data: Data, state: PersistedState)] = []
        // Keep every candidate locked until commit, so an old client cannot race the migration.
        for legacy in legacyDirectories where files.fileExists(atPath: legacy.appendingPathComponent("state.json").path) {
            let descriptor = try lock(legacy.appendingPathComponent("state.lock"))
            descriptors.append(descriptor)
            guard let data = try? boundedRead(legacy.appendingPathComponent("state.json"), limit: AssetLimits.stateBytes),
                  let state = try? ManifestVerifier.verifiedState(data, config: configuration) else { continue }
            verified.append((legacy, data, state))
        }
        guard let newest = verified.max(by: { $0.state.highestSequence < $1.state.highestSequence }) else { return nil }
        for candidate in verified where candidate.state.highestSequence == newest.state.highestSequence {
            guard Data(candidate.state.history[0].payload.utf8) == Data(newest.state.history[0].payload.utf8) else {
                throw AssetLibError.invalid("Conflicting legacy state reused a release sequence.")
            }
        }
        try migrateCache(from: verified.map(\.directory), state: newest.state)
        // Mark first: an interrupted commit fails closed instead of ever importing old state again.
        try markNamespaceUsed()
        try newest.data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        // Only verified legacy state is moved. Unverified entries and unrelated files are untouched.
        for candidate in verified { try? files.removeItem(at: candidate.directory.appendingPathComponent("state.json")) }
        return newest.data
    }

    private func markNamespaceUsed() throws {
        let marker = directory.appendingPathComponent("namespace-v2")
        if !files.fileExists(atPath: marker.path) { try Data("2\n".utf8).write(to: marker, options: .atomic) }
    }

    private func migrateCache(from legacy: [URL], state: PersistedState) throws {
        let descriptor = try lock(directory.appendingPathComponent("cache.lock"))
        defer { unlock(descriptor) }
        var hashes: [String] = []
        var seen = Set<String>()
        for envelope in state.history {
            for slot in try ManifestVerifier.verify(envelope, config: configuration).slots {
                let images = [slot] + (slot.cells ?? []).map(slot.selecting)
                for image in images {
                    for hash in [image.sha256] + (image.renditions ?? []).map(\.sha256) where seen.insert(hash).inserted {
                        hashes.append(hash)
                    }
                }
            }
        }
        var count = 0, bytes = 0
        for hash in hashes {
            guard count < AssetLimits.cacheEntries else { break }
            for source in legacy {
                let data = ["asset", "webp"].lazy.compactMap { ext in
                    try? self.boundedRead(source.appendingPathComponent(hash + "." + ext), limit: AssetLimits.assetBytes)
                }.first { hashBytes($0) == hash }
                guard let data, bytes + data.count <= AssetLimits.cacheBytes else { continue }
                try data.write(to: directory.appendingPathComponent(hash + ".asset"), options: .atomic)
                count += 1; bytes += data.count
                break
            }
        }
        try pruneCache()
    }

    private func lock(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AssetLibError.invalid("Unable to lock asset storage.") }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw AssetLibError.invalid("Unable to lock asset storage.")
        }
        return descriptor
    }
    private func unlock(_ descriptor: Int32) { flock(descriptor, LOCK_UN); close(descriptor) }
    public func asset(for hash: String) throws -> Data? {
        guard matches(hash, hashPattern) else { throw AssetLibError.invalid("Invalid cache key.") }
        // Preserve caches from the original WebP-only preview; bytes are verified by the client.
        if let data = try boundedRead(directory.appendingPathComponent(hash + ".asset"), limit: AssetLimits.assetBytes) { return data }
        return try boundedRead(directory.appendingPathComponent(hash + ".webp"), limit: AssetLimits.assetBytes)
    }
    public func saveAsset(_ data: Data, hash: String) throws {
        guard matches(hash, hashPattern), data.count <= AssetLimits.assetBytes, hashBytes(data) == hash else { throw AssetLibError.invalid("Invalid cache entry.") }
        let descriptor = open(directory.appendingPathComponent("cache.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AssetLibError.invalid("Unable to lock asset cache.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AssetLibError.invalid("Unable to lock asset cache.") }
        defer { flock(descriptor, LOCK_UN) }
        try data.write(to: directory.appendingPathComponent(hash + ".asset"), options: .atomic)
        try pruneCache()
    }
    /// Caller holds cache.lock, including when importing an older namespace.
    private func pruneCache() throws {
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { ["webp", "asset"].contains($0.pathExtension) }
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
