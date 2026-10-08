import SwiftUI
import Observation
import ImageIO

/// Read image(in:) inside a SwiftUI body. The returned Image remains fully native and caller-modifiable.
@MainActor @Observable
public final class AssetImageStore {
    public private(set) var results: [AssetReference: ResolvedAsset] = [:]
    public private(set) var release: Int = 0
    public private(set) var lastError: String?
    public private(set) var connected = false
    public private(set) var isLoading = false
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
    public func image(for reference: AssetReference, fallback: Image) -> Image { images[reference] ?? fallback }

    /// Explicit lifecycle work; getters never start requests. A generation check blocks stale connection results.
    /// Supply physical pixel targets for known layouts; omitted entries use the logical reference size.
    public func refresh(_ references: [AssetReference], targetPixels: [AssetReference: AssetPixelSize] = [:]) async {
        guard let client else { return }
        generation &+= 1
        let operation = generation
        isLoading = true
        defer { if generation == operation { isLoading = false } }
        let initial = await client.initialize()
        guard generation == operation, !Task.isCancelled else { return }
        release = initial.sequence
        for reference in references {
            let resolved = await client.resolve(reference, download: false, targetPixels: targetPixels[reference])
            guard generation == operation, !Task.isCancelled else { return }
            apply(resolved, for: reference)
        }
        let refreshed = await client.refresh()
        guard generation == operation, !Task.isCancelled else { return }
        release = refreshed.sequence; lastError = refreshed.error
        for reference in references {
            let resolved = await client.resolve(reference, download: refreshed.error == nil, targetPixels: targetPixels[reference])
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
