#if canImport(AVFoundation) && canImport(AVKit) && canImport(SwiftUI)
import AVFoundation
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Plays a placement's verified short looping clip, muted and without controls, over its poster.
///
/// The poster shows until the first frame renders, under reduced motion, on any failure, while the view is off
/// screen or the app is in the background, and when two other clips are already playing.
public struct AssetLoopingVideo: View {
    private let client: AssetClient
    private let reference: AssetReference
    private let poster: Image
    private let contentMode: ContentMode
    @StateObject private var model = LoopingVideoModel()

    /// Pass the placement's resolved image (or bundled fallback) as `poster`; apply your own accessibility label to this view.
    public init(client: AssetClient, reference: AssetReference, poster: Image, contentMode: ContentMode = .fit) {
        self.client = client
        self.reference = reference
        self.poster = poster
        self.contentMode = contentMode
    }

    public var body: some View {
        poster.resizable().aspectRatio(contentMode: contentMode)
            .overlay {
                if model.isPlaying, let player = model.player {
                    PlayerLayerView(player: player, gravity: contentMode == .fill ? .resizeAspectFill : .resizeAspect) {
                        model.firstFrameRendered()
                    }
                    .opacity(model.showsPoster ? 0 : 1)
                    .accessibilityHidden(true)
                }
            }
        .onAppear {
            model.reduceMotion = LoopingVideoModel.systemReduceMotion
            model.visible = true
        }
        .onDisappear { model.visible = false }
        // Under reduced motion nothing is downloaded; turning it off resolves the clip.
        .task(id: LoadKey(reference: reference, reduceMotion: model.reduceMotion)) {
            await model.load(client: client, reference: reference)
        }
        .onReceive(LoopingVideoModel.reduceMotionChanges) { _ in model.reduceMotion = LoopingVideoModel.systemReduceMotion }
        .onReceive(NotificationCenter.default.publisher(for: LoopingVideoModel.didEnterBackground)) { _ in model.foreground = false }
        .onReceive(NotificationCenter.default.publisher(for: LoopingVideoModel.willEnterForeground)) { _ in model.foreground = true }
    }

    private struct LoadKey: Hashable {
        let reference: AssetReference
        let reduceMotion: Bool
    }
}

/// Playback state for one `AssetLoopingVideo`. Internal so tests can drive the rules without a window.
@MainActor
final class LoopingVideoModel: ObservableObject {
    @Published var visible = false { didSet { update() } }
    @Published var foreground = true { didSet { update() } }
    @Published var reduceMotion = false { didSet { update() } }
    @Published private(set) var clip: URL?
    @Published private(set) var failed = false
    @Published private(set) var holdsSlot = false
    @Published private(set) var player: AVQueuePlayer?
    @Published private(set) var frameRendered = false
    private var loadedReference: AssetReference?
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    private let slots: LoopingVideoSlots

    init(slots: LoopingVideoSlots = .shared, reduceMotion: Bool = LoopingVideoModel.systemReduceMotion) {
        self.slots = slots
        self.reduceMotion = reduceMotion
    }

    var wantsToPlay: Bool { clip != nil && visible && foreground && !reduceMotion && !failed }
    var isPlaying: Bool { wantsToPlay && holdsSlot }
    var showsPoster: Bool { !isPlaying || !frameRendered }

    /// Resolves again on every appearance, so a newly published clip or a removed one takes effect.
    func load(client: AssetClient, reference: AssetReference) async {
        if loadedReference != reference { show(nil, for: reference) }
        guard !reduceMotion else { return }
        let video = await client.resolveVideo(reference)
        guard !Task.isCancelled, loadedReference == reference, video.fileURL != clip else { return }
        show(video.fileURL, for: reference)
    }

    /// Sets the verified clip directly; `load` is the only production caller.
    func show(_ url: URL?, for reference: AssetReference?) {
        loadedReference = reference
        clip = url
        failed = false
        teardown()
        update()
    }

    func firstFrameRendered() { if player != nil { frameRendered = true } }

    /// A player or looper failure returns this view to its poster.
    func playbackFailed() {
        failed = true
        update()
    }

    /// Called by `LoopingVideoSlots` when a waiting view is promoted.
    func granted() {
        holdsSlot = true
        syncPlayer()
    }

    private func update() {
        if wantsToPlay {
            if !holdsSlot { holdsSlot = slots.request(self) }
        } else {
            slots.relinquish(self)
            holdsSlot = false
        }
        syncPlayer()
    }

    private func syncPlayer() {
        guard isPlaying, let clip else { teardown(); return }
        if player == nil {
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            let looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: clip))
            let failed: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.playbackFailed() } }
            observations = [
                looper.observe(\.status) { looper, _ in if looper.status == .failed { failed() } },
                queue.observe(\.status) { queue, _ in if queue.status == .failed { failed() } },
                queue.observe(\.currentItem?.status) { queue, _ in if queue.currentItem?.status == .failed { failed() } },
            ]
            self.looper = looper
            player = queue
        }
        player?.play()
    }

    private func teardown() {
        observations.forEach { $0.invalidate() }
        observations = []
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        frameRendered = false
    }

    static var systemReduceMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    #if canImport(UIKit)
    static var reduceMotionChanges: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
    }
    static let didEnterBackground = UIApplication.didEnterBackgroundNotification
    static let willEnterForeground = UIApplication.willEnterForegroundNotification
    #else
    static var reduceMotionChanges: NotificationCenter.Publisher {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
    }
    static let didEnterBackground = NSApplication.didHideNotification
    static let willEnterForeground = NSApplication.didUnhideNotification
    #endif
}

/// Grants at most `capacity` concurrent players; waiting views keep their poster and are promoted in order.
@MainActor
final class LoopingVideoSlots {
    static let shared = LoopingVideoSlots(capacity: 2)
    let capacity: Int
    private var holders: [Entry] = []
    private var waiters: [Entry] = []
    private struct Entry { weak var model: LoopingVideoModel? }

    init(capacity: Int) { self.capacity = capacity }

    var playingCount: Int { holders.filter { $0.model != nil }.count }

    /// True when `model` holds a slot. Otherwise it waits in order, keeping its place on repeated requests.
    func request(_ model: LoopingVideoModel) -> Bool {
        if holders.contains(where: { $0.model === model }) { return true }
        if !waiters.contains(where: { $0.model === model }) { waiters.append(Entry(model: model)) }
        promote(requester: model)
        return holders.contains { $0.model === model }
    }

    func relinquish(_ model: LoopingVideoModel) {
        holders.removeAll { $0.model === model }
        waiters.removeAll { $0.model === model }
        promote(requester: nil)
    }

    private func promote(requester: LoopingVideoModel?) {
        holders.removeAll { $0.model == nil }
        waiters.removeAll { $0.model == nil }
        while holders.count < capacity, !waiters.isEmpty {
            guard let next = waiters.removeFirst().model else { continue }
            holders.append(Entry(model: next))
            if next !== requester { next.granted() }
        }
    }
}

#if canImport(UIKit)
private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var readiness: NSKeyValueObservation?
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onFirstFrame: @MainActor () -> Void

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.isUserInteractionEnabled = false
        view.readiness = observeFirstFrame(view.playerLayer, onFirstFrame)
        return view
    }
    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }
    static func dismantleUIView(_ view: PlayerLayerUIView, coordinator: ()) {
        view.readiness?.invalidate()
        view.playerLayer.player = nil
    }
}
#else
private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var readiness: NSKeyValueObservation?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { playerLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onFirstFrame: @MainActor () -> Void

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.readiness = observeFirstFrame(view.playerLayer, onFirstFrame)
        return view
    }
    func updateNSView(_ view: PlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }
    static func dismantleNSView(_ view: PlayerLayerNSView, coordinator: ()) {
        view.readiness?.invalidate()
        view.playerLayer.player = nil
    }
}
#endif

private func observeFirstFrame(_ layer: AVPlayerLayer, _ onFirstFrame: @escaping @MainActor () -> Void) -> NSKeyValueObservation {
    layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
        guard layer.isReadyForDisplay else { return }
        Task { @MainActor in onFirstFrame() }
    }
}
#endif
