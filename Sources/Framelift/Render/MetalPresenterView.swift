// SPDX-License-Identifier: AGPL-3.0-only
// CAMetalLayer view presenting 4:2:0 frames, driven by a per-screen NSView.displayLink on a render thread.
// No CPU waits on the GPU: frame textures stay alive through command-buffer handlers.
import AppKit
import CoreVideo
import Metal
import QuartzCore

/// A run loop thread that owns the display link, the pacer and all presentation state.
final class RenderThread: Thread, @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "framelift.render"
        qualityOfService = .userInteractive
        start()
        started.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // Keep the run loop alive with no other sources.
        var ctx = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(nil, 0, &ctx)
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        started.signal()
        while !isCancelled {
            autoreleasepool { _ = CFRunLoopRunInMode(.defaultMode, 1.0, false) }
        }
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// One-shot timer at host time `hostSeconds` (CACurrentMediaTime base) on this thread.
    func schedule(atHostTime hostSeconds: Double, _ block: @escaping () -> Void) -> CFRunLoopTimer? {
        guard let runLoop else { return nil }
        let fire = CFAbsoluteTimeGetCurrent() + (hostSeconds - CACurrentMediaTime())
        let timer = CFRunLoopTimerCreateWithHandler(nil, fire, 0, 0, 0) { _ in block() }
        CFRunLoopTimerSetTolerance(timer, 0)
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
        return timer
    }

    func addDisplayLink(_ add: @escaping (RunLoop) -> Void) {
        perform { add(RunLoop.current) }
    }

    func stop() {
        cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// One display-link callback, on the render thread.
struct DisplayTick {
    /// Host time (s) at which a frame committed now will be on screen.
    var targetTime: Double
    /// Refresh period of the screen the view is on (s).
    var refresh: Double
    /// Always nil with NSView.displayLink.
    var drawable: CAMetalDrawable?
}

protocol PresenterClient: AnyObject {
    /// Render thread.
    func presenter(_ view: MetalPresenterView, tick: DisplayTick)
    /// Main thread: the window moved to another screen (or the link was rebuilt).
    func presenterScreenChanged(_ view: MetalPresenterView, display: DisplayInfo?)
    /// Main thread: the window became visible or not (occlusion, hidden, minimised).
    func presenterVisibilityChanged(_ view: MetalPresenterView, visible: Bool)
}

extension PresenterClient {
    func presenterVisibilityChanged(_ view: MetalPresenterView, visible: Bool) {}
}

/// 3 drawables are needed to reach the direct display path (no compositor pass); with 2 the layer
/// can stay composited, costing a refresh, but a slow Mac drops fewer frames.
enum DisplayBuffering: String, CaseIterable, Identifiable {
    case double, triple
    var id: String { rawValue }
    static let defaultsKey = "framelift.buffering.v1"
    var drawableCount: Int { self == .triple ? 3 : 2 }
    var title: String { self == .triple ? "3 (default)" : "2" }
    static func stored(_ defaults: UserDefaults = .standard) -> DisplayBuffering {
        defaults.string(forKey: defaultsKey).flatMap(DisplayBuffering.init(rawValue:)) ?? .triple
    }
}

final class MetalPresenterView: NSView {
    weak var client: PresenterClient?
    /// From the "Display buffers" setting (DisplayBuffering), applied live.
    private static var drawableCount: Int { DisplayBuffering.stored().drawableCount }
    let renderThread = RenderThread()

    private(set) var metalLayer: CAMetalLayer!
    /// Pin the link at 60 Hz on 120 Hz screens.
    var preferSixtyHz = false { didSet { if oldValue != preferSixtyHz, window != nil { rebuildDisplayLink() } } }
    private var context: RenderContext?
    /// Final-present encoder (YUV->RGB, upscale, HUD). Render thread.
    private(set) var presentEncoder: PresentEncoder?
    private var hud: HUDText?
    var sharpness: Float = Float(StreamSettingsLimits.defaultSharpness)
    var upscaler: Upscaler = .sharp
    /// Method the last present used (render thread).
    private(set) var lastUpscaleMethod: UpscaleMethod = .bilinear
    /// Colour handling (any thread; applied on the next present). Follows the app setting stored
    /// under `ColourMode.defaultsKey` live.
    var colourMode: ColourMode {
        get { stateLock.withLock { _colourMode } }
        set { stateLock.withLock { _colourMode = newValue } }
    }
    private var _colourMode = ColourMode.stored()
    private var defaultsObserver: NSObjectProtocol?
    private var colourSource: (tags: ColourTags, mode: ColourMode)?
    private var requestedLayerSpace = LayerColourSpace.sRGB
    private var requestedLayerRevision = 0
    private var appliedLayerRevision = 0
    /// Render thread: lines of the in-frame HUD, nil hides it. Drawn in the same render pass
    /// as the video (no overlay layer), so direct-to-display stays possible.
    func setHUD(_ lines: [HUDLine]?) {
        guard let lines else { hudVisible = false; return }
        hud?.update(lines)
        hudVisible = true
    }
    private var hudVisible = false
    private var viewLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?
    private var visibilityObservers: [NSObjectProtocol] = []
    private var _visibility = "visible=? active=? space=? key=?"
    private var lastVisible: Bool?
    private var lastSlowDrawableLog: Double = 0
    private let stateLock = NSLock()
    private var _display: DisplayInfo?
    private var _screenRefresh: Double = 1.0 / 60
    private var lastTarget: Double = 0
    private var measuredRefresh: Double = 0

    var display: DisplayInfo? { stateLock.withLock { _display } }
    /// Window visibility for the event log (any thread): occlusion, app active, Space, key.
    var visibilitySummary: String { stateLock.withLock { _visibility } }
    /// The screen's refresh as last read; a change (e.g. Variable <-> fixed) rebuilds the display link.
    private var _refreshCapability: RefreshCapability?
    private var screenParamsObserver: NSObjectProtocol?
    var linkKind: String { viewLink != nil ? "NSView.displayLink" : "none" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        viewLink?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        for o in visibilityObservers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
        renderThread.stop()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        do {
            let ctx = try RenderContext.shared()
            context = ctx
            presentEncoder = try PresentEncoder(context: ctx)
            hud = HUDText(device: ctx.device)
        } catch {
            NSLog("[render] presenter setup failed: %@", "\(error)")
        }
        // The Settings "Colour" and "Display buffers" pickers write UserDefaults; apply them live.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.colourMode = ColourMode.stored()
            let count = Self.drawableCount
            DispatchQueue.main.async {
                guard let self, let layer = self.metalLayer, layer.maximumDrawableCount != count else { return }
                layer.maximumDrawableCount = count
                Diagnostics.shared.event("render: display buffering \(count) drawables")
            }
        }
        // Switching the display to Variable (or back) mid-stream changes no window screen: re-read it.
        screenParamsObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    private func screenParametersChanged() {
        guard let screen = window?.screen else { return }
        let now = RefreshCapability.of(screen)
        if stateLock.withLock({ _refreshCapability }) != now { rebuildDisplayLink() }
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = context?.device ?? MTLCreateSystemDefaultDevice()
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.maximumDrawableCount = Self.drawableCount
        l.presentsWithTransaction = false
        l.displaySyncEnabled = true
        l.wantsExtendedDynamicRangeContent = false
        // Default mapping's space (sRGB) until the first frame's tags arrive; see ColourPipeline.swift.
        l.colorspace = LayerColourSpace.sRGB.makeColorSpace()
        l.backgroundColor = NSColor.black.cgColor
        l.isOpaque = true
        l.allowsNextDrawableTimeout = true
        metalLayer = l
        return l
    }

    // MARK: Geometry

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for o in visibilityObservers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        visibilityObservers.removeAll()
        if let window {
            screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                Diagnostics.shared.event("render: window screen changed to \(self.window?.screen?.localizedName ?? "none") (\(self.visibilitySummary))")
                self.updateDrawableSize()
                self.rebuildDisplayLink()
            }
            let nc = NotificationCenter.default
            let update: (Notification) -> Void = { [weak self] _ in self?.updateVisibility() }
            visibilityObservers = [
                nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: update),
                nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main, using: update),
                nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main, using: update),
                nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: update),
                nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: update),
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                    queue: .main, using: update),
            ]
        }
        updateDrawableSize()
        rebuildDisplayLink()
        updateVisibility()
    }

    /// Main thread. Caches the window's visibility for the event log and tells the client when
    /// it becomes visible or not (an occluded window's presents are dropped by the window server).
    private func updateVisibility() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible) && window.isVisible && !window.isMiniaturized
        let summary = "visible=\(visible ? 1 : 0) active=\(NSApp.isActive ? 1 : 0) space=\(window.isOnActiveSpace ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0)"
        let changed = stateLock.withLock { () -> Bool in
            let changed = summary != _visibility
            _visibility = summary
            return changed
        }
        if changed { Diagnostics.shared.event("render: window \(summary)") }
        if visible != lastVisible {
            lastVisible = visible
            client?.presenterVisibilityChanged(self, visible: visible)
        }
    }

    // MARK: Display link

    /// Main thread. Recreates the display link for the screen the window is on now.
    func rebuildDisplayLink() {
        dispatchPrecondition(condition: .onQueue(.main))
        viewLink?.invalidate(); viewLink = nil
        guard let window, let screen = window.screen else {
            stateLock.withLock { _display = nil }
            client?.presenterScreenChanged(self, display: nil)
            return
        }
        let info = DisplayCatalog.info(for: screen)
        let hz = info?.refreshHz ?? 60
        let capability = RefreshCapability.of(screen)
        stateLock.withLock {
            _display = info
            _refreshCapability = capability
        }
        Diagnostics.shared.event("render: refresh \(screen.localizedName) \(capability.summary) -> fixed vsync pacing")
        var maxRate = Float(screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : Int(hz.rounded()))
        var effectiveHz = hz
        let multipleOf60 = (hz / 60).rounded()
        if preferSixtyHz && maxRate >= 119 && abs(multipleOf60 - hz / 60) < 0.02 {
            maxRate = 60
            effectiveHz = hz / multipleOf60
        }
        let rateRange = CAFrameRateRange(minimum: maxRate, maximum: maxRate, preferred: maxRate)
        let link = displayLink(target: self, selector: #selector(viewLinkFired(_:)))
        link.preferredFrameRateRange = rateRange
        viewLink = link
        renderThread.addDisplayLink { link.add(to: $0, forMode: .default) }
        stateLock.withLock { _screenRefresh = 1 / effectiveHz }
        lastTarget = 0
        measuredRefresh = 0
        client?.presenterScreenChanged(self, display: info)
    }

    /// Refresh period: measured from consecutive targets when stable, else the screen's mode.
    private func refresh(for target: Double) -> Double {
        let nominal = stateLock.withLock { _screenRefresh }
        if lastTarget > 0 {
            let d = target - lastTarget
            if d > nominal * 0.5 && d < nominal * 1.5 {
                measuredRefresh = measuredRefresh == 0 ? d : measuredRefresh + (d - measuredRefresh) * 0.05
            }
        }
        lastTarget = target
        if measuredRefresh > 0 && abs(measuredRefresh - nominal) < nominal * 0.05 { return measuredRefresh }
        return nominal
    }

    @objc private func viewLinkFired(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        var r = refresh(for: target)
        if link.duration > 0.002 && link.duration < 0.05 { r = link.duration }
        client?.presenter(self, tick: DisplayTick(targetTime: target, refresh: r, drawable: nil))
    }

    // MARK: Rendering (render thread)

    private func updateColour(_ tags: ColourTags, mode: ColourMode) {
        if let source = colourSource, source.tags == tags, source.mode == mode { return }
        colourSource = (tags, mode)
        let mapping = ColourMapping.decide(tags, mode: mode)
        presentEncoder?.colour = mapping
        Diagnostics.shared.event("colour: \(tags.summary) mode=\(mode.rawValue) -> \(mapping.summary)")
        let wanted = mapping.layer
        guard wanted != requestedLayerSpace else { return }
        requestedLayerSpace = wanted
        requestedLayerRevision += 1
        let revision = requestedLayerRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.metalLayer else { return }
            layer.pixelFormat = wanted.isHDR ? .bgr10a2Unorm : .bgra8Unorm
            layer.wantsExtendedDynamicRangeContent = wanted.isHDR
            layer.colorspace = wanted.makeColorSpace()
            self.stateLock.withLock { self.appliedLayerRevision = revision }
        }
    }

    /// Draws `frame` aspect-fit into the drawable (or the layer's next one) and presents it, in one
    /// command buffer.
    /// `onPresented` gets the actual on-glass host time (0 when the drawable was dropped).
    @discardableResult
    func render(
        _ frame: CVPixelBuffer, tags: ColourTags, drawable given: CAMetalDrawable?, targetTime: Double, refresh: Double,
        onPresented: ((Double) -> Void)? = nil
    ) -> Bool {
        guard let ctx = context, let presentEncoder, let metalLayer else { return false }
        let (mode, appliedRevision) = stateLock.withLock { (_colourMode, appliedLayerRevision) }
        updateColour(tags, mode: mode)
        // Drop drawables from before the colour-space change, including any supplied by the display link.
        guard appliedRevision == requestedLayerRevision else { return false }
        let format: MTLPixelFormat = requestedLayerSpace.isHDR ? .bgr10a2Unorm : .bgra8Unorm
        let asked = CACurrentMediaTime()
        let next = given ?? metalLayer.nextDrawable()
        let waited = CACurrentMediaTime() - asked
        if waited > 0.1, asked - lastSlowDrawableLog >= 1 {
            // The window server is not giving drawables back.
            lastSlowDrawableLog = asked
            Diagnostics.shared.event(
                String(
                    format: "render: nextDrawable blocked %.0f ms (%@)%@", waited * 1000, visibilitySummary,
                    next == nil ? ", none" : ""))
        }
        guard let drawable = next, drawable.texture.pixelFormat == format, let cb = ctx.queue.makeCommandBuffer() else { return false }
        cb.label = "framelift.present"
        presentEncoder.sharpness = sharpness
        presentEncoder.upscaler = upscaler
        guard
            let (method, keep) = presentEncoder.encode(
                frame, into: drawable.texture, commandBuffer: cb,
                hud: hudVisible ? hud?.texture : nil)
        else { return false }
        if method != lastUpscaleMethod {
            lastUpscaleMethod = method
            Diagnostics.shared.event(
                "render: present \(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame)) -> \(drawable.texture.width)x\(drawable.texture.height) via \(method.rawValue)"
            )
        }
        if let onPresented {
            drawable.addPresentedHandler { d in onPresented(d.presentedTime) }
        }
        if given != nil {
            cb.present(drawable)
        } else {
            cb.present(drawable, atTime: targetTime - refresh * 0.5)  // half a refresh before the target vsync
        }
        cb.addCompletedHandler { cb in
            GPUTiming.shared.addPresent(cb)
            withExtendedLifetime((keep, frame)) {}
        }
        cb.commit()
        return true
    }
}
