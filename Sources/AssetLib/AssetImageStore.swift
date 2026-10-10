import SwiftUI
import Observation
import ImageIO

/// A synchronous snapshot pairing a native image with its optional content description.
/// Read inside the view body. No accessibility modifiers are applied automatically.
public struct AssetArtwork {
    public let image: Image
    public let accessibilityDescription: String?
    public let source: AssetSource
}

/// Read image(in:) inside a SwiftUI body. The returned Image remains fully native and caller-modifiable.
@MainActor @Observable
public final class AssetImageStore {
    public private(set) var results: [AssetReference: ResolvedAsset] = [:]
    public private(set) var release: Int = 0
    public private(set) var lastError: String?
    public private(set) var connected = false
    public private(set) var isLoading = false
    /// Feed the view's color scheme here, then explicitly refresh to load that appearance.
    public var appearance: AssetAppearance? {
        didSet { if appearance != oldValue { invalidateSelection() } }
    }
    /// Per-reference explicit arm assignments. Use "control" to bypass the decision callback.
    public var arm: [AssetReference: String] = [:] {
        didSet { if arm != oldValue { invalidateSelection() } }
    }
    private var images: [AssetReference: Image] = [:]
    @ObservationIgnored private var imageCosts: [AssetReference: Int] = [:]
    @ObservationIgnored private var imageOrder: [AssetReference] = []
    @ObservationIgnored private var client: AssetClient?
    @ObservationIgnored private var generation: UInt64 = 0

    public init() {}
    public func connect(_ client: AssetClient) {
        generation &+= 1
        self.client = client
        connected = true
        images.removeAll(); results.removeAll(); release = 0; lastError = nil; isLoading = false
        imageCosts.removeAll(); imageOrder.removeAll()
    }
    public func disconnect() {
        generation &+= 1
        client = nil; connected = false; isLoading = false
        images.removeAll(); results.removeAll(); release = 0; lastError = nil
        imageCosts.removeAll(); imageOrder.removeAll()
    }
    private func invalidateSelection() {
        generation &+= 1
        isLoading = false
        images.removeAll(); results.removeAll()
        imageCosts.removeAll(); imageOrder.removeAll()
    }
    /// A `.template` reference returns its remote or bundled image with template rendering, ready for `foregroundStyle`.
    public func image(for reference: AssetReference, fallback: Image) -> Image { rendered(images[reference] ?? fallback, for: reference) }

    /// Opt in to paired descriptions. Informative placements can keep their bundled image when a
    /// remote release has no description. The app still owns its label, hiding, and control traits.
    public func artwork(for reference: AssetReference, fallback: Image,
                        bundledAccessibility: AssetAccessibility? = nil, locale: Locale = .current,
                        requireDescription: Bool = false) -> AssetArtwork {
        if let image = images[reference], let result = results[reference],
           !requireDescription || result.accessibility != nil {
            return AssetArtwork(image: rendered(image, for: reference), accessibilityDescription: result.accessibility?.localizedDescription(locale: locale), source: result.source)
        }
        return AssetArtwork(image: rendered(fallback, for: reference), accessibilityDescription: bundledAccessibility?.localizedDescription(locale: locale), source: .bundle)
    }
    private func rendered(_ image: Image, for reference: AssetReference) -> Image {
        reference.rendering == .template ? image.renderingMode(.template) : image
    }

    /// Explicit lifecycle work; getters never start requests. A generation check blocks stale connection results.
    /// Supply physical pixel targets for known layouts; omitted entries use the logical reference size.
    public func refresh(_ references: [AssetReference], targetPixels: [AssetReference: AssetPixelSize] = [:]) async {
        guard let client else { return }
        generation &+= 1
        let operation = generation
        let requestedAppearance = appearance
        let requestedArms = arm
        isLoading = true
        defer { if generation == operation { isLoading = false } }
        let initial = await client.initialize()
        guard generation == operation, !Task.isCancelled else { return }
        release = initial.sequence
        for reference in references {
            let resolved = await client.resolve(reference, download: false, targetPixels: targetPixels[reference], appearance: requestedAppearance, arm: requestedArms[reference])
            guard generation == operation, !Task.isCancelled else { return }
            apply(resolved, for: reference)
        }
        let refreshed = await client.refresh()
        guard generation == operation, !Task.isCancelled else { return }
        release = refreshed.sequence; lastError = refreshed.error
        for reference in references {
            let resolved = await client.resolve(reference, download: refreshed.error == nil, targetPixels: targetPixels[reference], appearance: requestedAppearance, arm: requestedArms[reference])
            guard generation == operation, !Task.isCancelled else { return }
            apply(resolved, for: reference)
        }
    }
    private func apply(_ resolved: ResolvedAsset, for reference: AssetReference) {
        results[reference] = resolved
        if let data = resolved.bytes, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            images[reference] = Image(decorative: decoded, scale: 1)
            imageCosts[reference] = decoded.bytesPerRow * decoded.height
            imageOrder.removeAll { $0 == reference }; imageOrder.append(reference)
            while imageOrder.count > 32 || imageCosts.values.reduce(0, +) > 64 * 1024 * 1024 {
                let oldest = imageOrder.removeFirst()
                images.removeValue(forKey: oldest); imageCosts.removeValue(forKey: oldest); results.removeValue(forKey: oldest)
            }
        } else {
            images.removeValue(forKey: reference); imageCosts.removeValue(forKey: reference)
            imageOrder.removeAll { $0 == reference }
        }
    }
}
