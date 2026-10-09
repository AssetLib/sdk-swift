import Foundation

/// Signature verification, delivery and durable release history. UI is deliberately outside this actor.
public actor AssetClient {
    public let configuration: AssetConfiguration
    private let storage: any AssetStorage
    private let transport: any AssetTransport
    private let supportedFormats: [AssetFormat]
    private let decide: (@Sendable (String, [String]) async -> String?)?
    private var state = PersistedState()
    private var initialized = false
    private var storageFailure: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var lastError: String?
    public var sequence: Int { state.highestSequence }

    /// The decision callback assigns an arm; the app logs exposure only after rendering artwork.
    /// It must not await initialize, refresh, or resolve on this same client while resolving.
    public init(configuration: AssetConfiguration, storage: any AssetStorage, transport: (any AssetTransport)? = nil, supportedFormats: [AssetFormat] = [.webP, .png], decide: (@Sendable (String, [String]) async -> String?)? = nil) throws {
        try configuration.validate()
        guard supportedFormats.contains(.webP), Set(supportedFormats).count == supportedFormats.count else {
            throw AssetLibError.invalid("Supported formats must be unique and include WebP for legacy fallback.")
        }
        self.configuration = configuration
        self.storage = storage
        self.transport = try transport ?? HTTPSAssetTransport()
        self.supportedFormats = supportedFormats
        self.decide = decide
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
    public func resolve(_ reference: AssetReference, download: Bool = true, targetPixels: AssetPixelSize? = nil, appearance: AssetAppearance? = nil, arm: String? = nil) async -> ResolvedAsset {
        await acquire(); defer { release() }
        await load()
        guard validReference(reference) else { return fallback("Invalid generated asset reference.") }
        let target = targetPixels ?? AssetPixelSize(width: reference.width, height: reference.height)
        guard target.isValid else { return fallback("Target pixel dimensions must each be between 1 and 8192.") }
        guard !Task.isCancelled else { return fallback("Artwork request cancelled.") }
        // Decide once from the current release, then keep that assignment through historical fallback.
        let current = state.history.first.flatMap { try? ManifestVerifier.verify($0, config: configuration) }
        let currentSlot = current?.slots.first { $0.key == reference.key && $0.width == reference.width && $0.height == reference.height }
        let decision = await decideArm(reference.key, slot: currentSlot, explicitArm: arm)
        guard !Task.isCancelled else { return fallback("Artwork request cancelled.", armSource: decision.source) }
        var message = storageFailure ?? "No compatible published artwork is available."
        for (index, envelope) in state.history.enumerated() {
            do {
                try Task.checkCancellation()
                let payload = try ManifestVerifier.verify(envelope, config: configuration)
                guard let slot = payload.slots.first(where: { $0.key == reference.key && $0.width == reference.width && $0.height == reference.height }) else { continue }
                let cell = selectedCell(in: slot, arm: decision.arm, appearance: appearance)
                let selected = cell.map { slot.selecting($0) } ?? slot
                // Both cache lookups and downloads use the selected cell's descriptor and hashes.
                for candidate in ManifestVerifier.candidates(selected, target: target, formats: supportedFormats) {
                    do {
                        try Task.checkCancellation()
                        if let data = try await storage.asset(for: candidate.sha256), let size = ManifestVerifier.decodedSize(data, candidate: candidate) {
                            return .init(source: .cache, sequence: payload.sequence, message: index == 0 ? "Verified artwork from this device." : "Using verified artwork from release \(payload.sequence). \(message)", bytes: data, sha256: candidate.sha256, assetID: selected.assetId, mime: candidate.mime, pixelSize: size, accessibility: selected.accessibility, appearance: cell?.appearance, arm: cell?.arm, armSource: decision.source)
                        }
                        guard index == 0, download else { continue }
                        let data = try await transport.get(ManifestVerifier.candidateURL(candidate, assetID: selected.assetId, config: configuration), maximumBytes: candidate.bytes, accept: candidate.mime)
                        try Task.checkCancellation()
                        guard let size = ManifestVerifier.decodedSize(data, candidate: candidate) else {
                            throw AssetLibError.invalid("Artwork does not match the signed bytes, type, or dimensions.")
                        }
                        try await storage.saveAsset(data, hash: candidate.sha256)
                        return .init(source: .remote, sequence: payload.sequence, message: "Downloaded and verified artwork.", bytes: data, sha256: candidate.sha256, assetID: selected.assetId, mime: candidate.mime, pixelSize: size, accessibility: selected.accessibility, appearance: cell?.appearance, arm: cell?.arm, armSource: decision.source)
                    } catch { message = error.localizedDescription }
                }
            } catch { message = error.localizedDescription }
        }
        return fallback(message, armSource: decision.source)
    }

    private func decideArm(_ key: String, slot: ManifestSlot?, explicitArm: String?) async -> (arm: String?, source: AssetArmSource) {
        if let explicitArm { return (explicitArm == "control" ? nil : explicitArm, .explicit) }
        guard let arms = slot?.variants?.arm, !arms.isEmpty, let decide else { return (nil, .control) }
        guard let arm = await decide(key, arms), arms.contains(arm) else { return (nil, .invalidDecision) }
        return (arm, .decision)
    }

    private func selectedCell(in slot: ManifestSlot, arm: String?, appearance: AssetAppearance?) -> ManifestCell? {
        let cells = slot.cells ?? []
        // Exact arm/appearance, arm/any, control/appearance, then the legacy slot fields.
        return arm.flatMap { arm in
            cells.first { $0.arm == arm && $0.appearance == appearance }
                ?? cells.first { $0.arm == arm && $0.appearance == nil }
        } ?? appearance.flatMap { appearance in
            cells.first { $0.arm == nil && $0.appearance == appearance }
        }
    }

    private func fallback(_ message: String, armSource: AssetArmSource = .control) -> ResolvedAsset {
        .init(source: .bundle, sequence: nil, message: "Using bundled artwork. \(message)", bytes: nil, sha256: nil, assetID: nil, mime: nil, pixelSize: nil, accessibility: nil, appearance: nil, arm: nil, armSource: armSource)
    }
}
