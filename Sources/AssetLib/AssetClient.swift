import Foundation

/// Signature verification, delivery and durable release history. UI is deliberately outside this actor.
public actor AssetClient {
    public let configuration: AssetConfiguration
    private let storage: any AssetStorage
    private let transport: any AssetTransport
    private var state = PersistedState()
    private var initialized = false
    private var storageFailure: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var lastError: String?
    public var sequence: Int { state.highestSequence }

    public init(configuration: AssetConfiguration, storage: any AssetStorage, transport: (any AssetTransport)? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        self.storage = storage
        self.transport = try transport ?? HTTPSAssetTransport()
    }

    // Actors may reenter across await. Serialize the full operation, including disk and network suspension points.
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
    public func initialize() async -> RefreshResult {
        await acquire(); defer { release() }
        await load()
        return .init(updated: false, sequence: state.highestSequence, error: storageFailure)
    }
    private func load() async {
        guard storageFailure == nil else { return }
        defer { initialized = true }
        do {
            guard let data = try await storage.loadState() else {
                guard state.highestSequence == 0 else { throw AssetLibError.invalid("Persisted release state disappeared.") }
                return
            }
            let decoded = try ManifestVerifier.verifiedState(data, config: configuration)
            guard decoded.highestSequence >= state.highestSequence else { throw AssetLibError.invalid("Persisted release sequence regressed.") }
            if decoded.highestSequence == state.highestSequence, let existing = state.history.first {
                guard Data(existing.payload.utf8) == Data(decoded.history[0].payload.utf8) else { throw AssetLibError.invalid("Persisted release content conflicted.") }
            }
            state = decoded
        } catch {
            state = PersistedState()
            storageFailure = "Stored release state could not be verified. Using bundled artwork; explicitly reset app data to repair it."
            lastError = storageFailure
        }
    }
    public func refresh() async -> RefreshResult {
        await acquire(); defer { release() }
        await load()
        do {
            try Task.checkCancellation()
            if let storageFailure { throw AssetLibError.invalid(storageFailure) }
            guard let url = URL(string: configuration.manifestUrl) else { throw AssetLibError.invalid("Invalid manifest URL.") }
            let data = try await transport.get(url, maximumBytes: AssetLimits.manifestBytes, accept: "application/json")
            try Task.checkCancellation()
            guard data.count <= AssetLimits.manifestBytes else { throw AssetLibError.invalid("Manifest exceeds its byte limit.") }
            let envelope = try JSONDecoder().decode(SignedManifest.self, from: data)
            let payload = try ManifestVerifier.verify(envelope, config: configuration)
            // A second client may have committed while this network request was in flight.
            await load()
            if let storageFailure { throw AssetLibError.invalid(storageFailure) }
            guard payload.sequence >= state.highestSequence else { throw AssetLibError.invalid("An older release was rejected.") }
            if payload.sequence == state.highestSequence {
                guard let existing = state.history.first, Data(envelope.payload.utf8) == Data(existing.payload.utf8) else { throw AssetLibError.invalid("Conflicting content reused a release sequence.") }
                lastError = nil
                return .init(updated: false, sequence: payload.sequence, error: nil)
            }
            let next = PersistedState(highestSequence: payload.sequence, history: Array(([envelope] + state.history).prefix(AssetLimits.retainedReleases)))
            let encoded = try JSONEncoder().encode(next)
            guard encoded.count <= AssetLimits.stateBytes else { throw AssetLibError.invalid("Release history exceeds its byte limit.") }
            try await storage.saveState(encoded)
            state = next
            lastError = nil
            return .init(updated: true, sequence: payload.sequence, error: nil)
        } catch {
            lastError = error.localizedDescription
            return .init(updated: false, sequence: state.highestSequence, error: lastError)
        }
    }
    public func resolve(_ reference: AssetReference, download: Bool = true) async -> ResolvedAsset {
        await acquire(); defer { release() }
        await load()
        guard validReference(reference) else { return fallback("Invalid generated asset reference.") }
        var message = storageFailure ?? "No compatible published artwork is available."
        for (index, envelope) in state.history.enumerated() {
            do {
                try Task.checkCancellation()
                let payload = try ManifestVerifier.verify(envelope, config: configuration)
                guard let slot = payload.slots.first(where: { $0.key == reference.key && $0.width == reference.width && $0.height == reference.height }) else { continue }
                if let data = try await storage.asset(for: slot.sha256), ManifestVerifier.validAsset(data, slot: slot) {
                    return .init(source: .cache, sequence: payload.sequence, message: index == 0 ? "Verified artwork from this device." : "Using verified artwork from release \(payload.sequence). \(message)", bytes: data, sha256: slot.sha256)
                }
                guard index == 0, download else { continue }
                let data = try await transport.get(ManifestVerifier.assetURL(slot, config: configuration), maximumBytes: slot.bytes, accept: "image/webp")
                try Task.checkCancellation()
                guard ManifestVerifier.validAsset(data, slot: slot) else { throw AssetLibError.invalid("Artwork does not match the signed bytes, type, or dimensions.") }
                try await storage.saveAsset(data, hash: slot.sha256)
                return .init(source: .remote, sequence: payload.sequence, message: "Downloaded and verified artwork.", bytes: data, sha256: slot.sha256)
            } catch { message = error.localizedDescription }
        }
        return fallback(message)
    }
    private func fallback(_ message: String) -> ResolvedAsset {
        .init(source: .bundle, sequence: nil, message: "Using bundled artwork. \(message)", bytes: nil, sha256: nil)
    }
}
