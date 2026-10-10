import Foundation

/// Signature verification, delivery and durable release history. UI is deliberately outside this actor.
public actor AssetClient {
    public let configuration: AssetConfiguration
    private let storage: any AssetStorage
    private let transport: any AssetTransport
    private let supportedFormats: [AssetFormat]
    private let decide: (@Sendable (String, [String]) async throws -> String?)?
    private let decisionTimeoutMilliseconds: Int
    private var state = PersistedState()
    private var initialized = false
    private var storageFailure: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var lastError: String?
    public var sequence: Int { state.highestSequence }

    /// The decision callback assigns an arm; the app logs exposure only after rendering artwork.
    /// It runs outside the operation gate and may call back into this client. A timeout, thrown
    /// error, nil, or undeclared arm selects control and includes a reason in the result message.
    /// The wait defaults to 1,500 milliseconds and must be between 100 and 10,000.
    public init(configuration: AssetConfiguration, storage: any AssetStorage, transport: (any AssetTransport)? = nil, supportedFormats: [AssetFormat] = [.webP, .png], decisionTimeoutMilliseconds: Int = 1_500, decide: (@Sendable (String, [String]) async throws -> String?)? = nil) throws {
        try configuration.validate()
        guard supportedFormats.contains(.webP), Set(supportedFormats).count == supportedFormats.count else {
            throw AssetLibError.invalid("Supported formats must be unique and include WebP for legacy fallback.")
        }
        guard (100...10_000).contains(decisionTimeoutMilliseconds) else {
            throw AssetLibError.invalid("Decision timeout must be between 100 and 10000 milliseconds.")
        }
        self.decisionTimeoutMilliseconds = decisionTimeoutMilliseconds
        self.configuration = configuration
        self.storage = storage
        self.transport = try transport ?? HTTPSAssetTransport()
        self.supportedFormats = supportedFormats
        self.decide = decide
    }

    // Actors may reenter across await. Serialize storage/network work, but never app decision callbacks.
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
        var decision = ArmDecision(arm: arm == "control" ? nil : arm, source: arm == nil ? .control : .explicit)
        if arm == nil, let arms = currentSlot(for: reference)?.variants?.arm, !arms.isEmpty, let decide {
            // Only the callback inputs cross this boundary. No release snapshot is used afterward.
            release()
            let outcome = await Self.evaluateDecision(decide, key: reference.key, arms: arms,
                                                      timeoutMilliseconds: decisionTimeoutMilliseconds)
            await acquire()
            await load()
            switch outcome {
            case .answer(let answer):
                if let answer, currentSlot(for: reference)?.variants?.arm?.contains(answer) == true {
                    decision = ArmDecision(arm: answer, source: .decision)
                } else {
                    decision = ArmDecision(arm: nil, source: .invalidDecision,
                        reason: answer == nil ? "Decision callback returned no arm. Using control." : "Decision callback returned an undeclared arm for the current release. Using control.")
                }
            case .invalid(let reason):
                decision = ArmDecision(arm: nil, source: .invalidDecision, reason: reason)
            }
        }
        guard !Task.isCancelled else { return fallback(decision.explain("Artwork request cancelled."), armSource: decision.source) }
        if let storageFailure { return fallback(decision.explain(storageFailure), armSource: decision.source) }
        var message = "No compatible published artwork is available."
        for (index, envelope) in state.history.enumerated() {
            do {
                try Task.checkCancellation()
                let payload = try ManifestVerifier.verify(envelope, config: configuration)
                guard let slot = payload.slots.first(where: { $0.key == reference.key && $0.width == reference.width && $0.height == reference.height }) else { continue }
                let cell = selectedCell(in: slot, arm: decision.arm, appearance: appearance)
                let selected = cell.map { slot.selecting($0) } ?? slot
                // Like a size mismatch: a different or unknown rendering is never read from cache or downloaded.
                guard (selected.rendering ?? AssetRendering.original.rawValue) == reference.rendering.rawValue else {
                    message = "Published artwork for this placement uses a different rendering."
                    continue
                }
                // Both cache lookups and downloads use the selected cell's descriptor and hashes.
                for candidate in ManifestVerifier.candidates(selected, target: target, formats: supportedFormats) {
                    do {
                        try Task.checkCancellation()
                        if let data = try await storage.asset(for: candidate.sha256), let size = ManifestVerifier.decodedSize(data, candidate: candidate) {
                            return .init(source: .cache, sequence: payload.sequence, message: decision.explain(index == 0 ? "Verified artwork from this device." : "Using verified artwork from release \(payload.sequence). \(message)"), bytes: data, sha256: candidate.sha256, assetID: selected.assetId, mime: candidate.mime, pixelSize: size, accessibility: selected.accessibility, appearance: cell?.appearance, arm: cell?.arm, armSource: decision.source)
                        }
                        guard index == 0, download else { continue }
                        let data = try await transport.get(ManifestVerifier.candidateURL(candidate, assetID: selected.assetId, config: configuration), maximumBytes: candidate.bytes, accept: candidate.mime)
                        try Task.checkCancellation()
                        guard let size = ManifestVerifier.decodedSize(data, candidate: candidate) else {
                            throw AssetLibError.invalid("Artwork does not match the signed bytes, type, or dimensions.")
                        }
                        try await storage.saveAsset(data, hash: candidate.sha256)
                        return .init(source: .remote, sequence: payload.sequence, message: decision.explain("Downloaded and verified artwork."), bytes: data, sha256: candidate.sha256, assetID: selected.assetId, mime: candidate.mime, pixelSize: size, accessibility: selected.accessibility, appearance: cell?.appearance, arm: cell?.arm, armSource: decision.source)
                    } catch { message = error.localizedDescription }
                }
            } catch { message = error.localizedDescription }
        }
        return fallback(decision.explain(message), armSource: decision.source)
    }

    private func currentSlot(for reference: AssetReference) -> ManifestSlot? {
        state.history.first.flatMap { try? ManifestVerifier.verify($0, config: configuration) }?.slots.first {
            $0.key == reference.key && $0.width == reference.width && $0.height == reference.height
        }
    }

    private struct ArmDecision {
        let arm: String?
        let source: AssetArmSource
        var reason: String? = nil
        func explain(_ message: String) -> String { reason.map { "\(message) \($0)" } ?? message }
    }

    private enum DecisionOutcome: Sendable {
        case answer(String?)
        case invalid(String)
    }

    private nonisolated static func evaluateDecision(
        _ decide: @escaping @Sendable (String, [String]) async throws -> String?,
        key: String, arms: [String], timeoutMilliseconds: Int
    ) async -> DecisionOutcome {
        // Unstructured tasks are intentional: a task group would join a callback that ignores
        // cancellation. Detached execution also keeps the callback's synchronous work off this
        // client's actor. The oldest buffer and single read select the first result; late completions
        // cannot change that selection.
        let (stream, continuation) = AsyncStream<DecisionOutcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let callback = Task.detached {
            do { continuation.yield(.answer(try await decide(key, arms))) }
            catch { continuation.yield(.invalid("Decision callback threw an error. Using control.")) }
            continuation.finish()
        }
        let timeout = Task.detached {
            do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)) }
            catch { return }
            continuation.yield(.invalid("Decision callback timed out after \(timeoutMilliseconds) milliseconds. Using control."))
            continuation.finish()
        }
        defer { callback.cancel(); timeout.cancel(); continuation.finish() }
        return await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? .invalid("Decision callback wait was cancelled. Using control.")
        } onCancel: {
            continuation.finish()
        }
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
