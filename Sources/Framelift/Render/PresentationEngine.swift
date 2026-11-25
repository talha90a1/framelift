// SPDX-License-Identifier: AGPL-3.0-only
// FrameSink: decoded frames -> frame interpolation + scene-cut test -> FramePacer -> MetalPresenterView.
// All mutable state lives on the view's render thread; submit() only hops onto it.
import AppKit
import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

final class PresentationEngine: FrameSink, PresenterClient, @unchecked Sendable {
    var onVideoPresented: ((Double, Double) -> Void)?
    var onFramePresented: ((CVPixelBuffer, ColourTags, Double) -> Void)?
    private let subtitles = SubtitleDetector()
    private let hud = HUDDetector()
    // MARK: Public knobs (not in the frozen StreamSettings; wire from the app)

    /// In-frame FPS/latency HUD (drawn in the Metal pass).
    var showFPSCounter: Bool {
        get { modeLock.withLock { _showFPS } }
        set {
            modeLock.withLock { _showFPS = newValue }
            perform { self.refreshHUD() }
        }
    }

    let telemetry: Telemetry
    let renderTelemetry: RenderTelemetry

    // MARK: State (render thread)

    private let view: MetalPresenterView
    private let thread: RenderThread
    private let modeLock = NSLock()
    private var _showFPS = false
    private var settings: StreamSettings
    private let internet: Bool
    private let ctx: RenderContext?
    /// Apple ML interpolation (VTFrameProcessor low-latency frame interpolation). Until its model
    /// is ready, real frames are shown on display cadence.
    private var llfi: AppleLLFIInterpolator?
    private var blender: FrameBlender?
    private var gateReason = "starting"
    private let cutDetector: SceneCutDetector?
    private let pacer = FramePacer()
    private var displayHz: Double = 60

    private var watchdog = PresentationWatchdog()

    private enum Source: UInt8 {
        // Raw values are the frames.csv backend column.
        case repeatReal = 4, appleML = 6
    }

    private struct Record {
        var frame: DecodedFrame
        var mids: [CVPixelBuffer] = []
        var cut: Bool?
    }
    private var records: [UInt64: Record] = [:]
    private var previous: DecodedFrame?
    private var nextID: UInt64 = 1
    private var epoch = 0

    private struct Wait {
        var id: UInt64
        var target: Double
        var refresh: Double
        var deadline: Double
        var drawable: CAMetalDrawable?
        var timer: CFRunLoopTimer?
    }
    private var wait: Wait?
    /// The last vsync's drawable when nothing was shown on it: something that becomes ready
    /// before its commit deadline is still presented on that vsync (no fixed added delay).
    private var held: (target: Double, refresh: Double, deadline: Double, drawable: CAMetalDrawable?)?

    // Duplicate-frame detection (a 60 fps stream carrying a 30 fps game).
    private var repeatedFrameCadence = RepeatedFrameCadence()
    private var effectiveFPS: Double = 30
    /// Typical SAD between consecutive new frames (repeat detection threshold).
    private var newFrameSad: Double = 0.02
    private var lastThumbnail: LumaThumbnail?

    private let stats = Stats()
    /// Display-link callback -> its target presentation time, ms (for the drops log line).
    private var linkLead = PercentileWindow(capacity: 120)
    private var interpSamples = 0
    private var lastTelemetryPush: Double = 0

    init(view: MetalPresenterView, settings: StreamSettings, internet: Bool = false, telemetry: Telemetry = .shared, renderTelemetry: RenderTelemetry = .shared) {
        self.view = view
        self.thread = view.renderThread
        self.settings = settings
        self.internet = internet
        self.telemetry = telemetry
        self.renderTelemetry = renderTelemetry
        ctx = try? RenderContext.shared()
        cutDetector = ctx.flatMap { try? SceneCutDetector(context: $0) }
        effectiveFPS = Double(settings.streamFPS)
        pacer.nominalInterval = 1 / max(1, effectiveFPS)
        if let d = view.display { displayHz = d.refreshHz }
        view.client = self
        // The link runs at the panel's own rate; the pacer places output on that grid.
        DispatchQueue.main.async { view.preferSixtyHz = false }
        perform {
            self.pacer.reset()
            self.rebuildBackends()
            self.view.sharpness = Float(settings.sharpness)
            self.view.upscaler = settings.upscaler
        }
        Diagnostics.shared.event(internet && settings.streamFPS >= 50
            ? "render: direct frames for 60 fps Internet Play"
            : "render: frame generation Apple ML interpolation")
    }

    private func perform(_ block: @escaping () -> Void) { thread.perform(block) }

    func update(settings new: StreamSettings) {
        perform {
            let old = self.settings
            self.settings = new
            self.view.sharpness = Float(new.sharpness)
            self.view.upscaler = new.upscaler
            if old.width != new.width || old.height != new.height || old.streamFPS != new.streamFPS || old.codec != new.codec {
                self.rebuildBackends()
            }
            if old.streamFPS != new.streamFPS || old.width != new.width || old.height != new.height {
                self.resetFrameCadence()
            }
        }
    }

    // MARK: FrameSink

    func submit(_ frame: DecodedFrame) {
        perform { self.receive(frame) }
    }

    func reset() {
        subtitles.reset()
        hud.reset()
        perform {
            self.epoch += 1
            self.records.removeAll()
            self.previous = nil
            self.resetFrameCadence()
            self.cancelWait()
            self.held = nil
            self.pacer.reset()
            self.interpSamples = 0
            self.llfi?.reset()
        }
    }

    // MARK: Backends

    private func rebuildBackends() {
        blender = nil
        llfi = nil
        interpSamples = 0
        pacer.reset()
        if internet && settings.streamFPS >= 50 {
            setGate("real frames (60 fps Internet Play)")
            return
        }
        guard let ctx else { setGate("none (no Metal)"); return }
        blender = try? FrameBlender(context: ctx)
        if AppleLLFIInterpolator.isSupported {
            let l = AppleLLFIInterpolator(keepWarm: settings.keepLLFIWarm)
            l.prepare(width: Int(settings.width), height: Int(settings.height))
            llfi = l
        }
        Diagnostics.shared.event("render: backend \(llfi?.backendName ?? "none (Apple ML unavailable)")")
    }

    private func displayAllowsGeneration() -> Bool {
        if effectiveFPS >= 50 {
            setGate("real frames (noGeneration60: 60 fps source)")
            return false
        }
        if 2 * displayHz < 3 * effectiveFPS - 0.5 {
            setGate("real frames (display too slow)")
            return false
        }
        return true
    }

    private func setGate(_ reason: String) {
        if reason != gateReason {
            Diagnostics.shared.event("render: generation \(reason)")
            gateReason = reason
        }
    }

    /// Watchdog transitions: log them, and on a resume forget everything learned while the glass
    /// was not being reached (present lag, drains).
    private func handleWatchdog(
        _ t: PresentationWatchdog.Transition?, target: Double? = nil,
        refresh: Double = 0, drawable: CAMetalDrawable? = nil
    ) {
        guard let t else { return }
        switch t {
        case .paused:
            Diagnostics.shared.event("render: presentation paused (\(view.visibilitySummary))")
        case let .stalled(committed, duration):
            Diagnostics.shared.event(
                String(
                    format: "render: presentation stalled (%d presents committed, none on the glass for %.0f ms; %@)",
                    committed, duration * 1000, view.visibilitySummary))
            // Start the pacer over and put the newest real frame up at once (it goes through
            // the same layer, so it shows only if the window server takes presents again).
            epoch += 1
            cancelWait()
            held = nil
            pacer.reset(keepingBudget: true)
            records.removeAll()
            if let frame = previous, let target {
                present(
                    frame.pixelBuffer, generated: false, first: false, frame: frame, drawable: drawable,
                    target: target, refresh: refresh)
            }
        case let .resumed(reason):
            Diagnostics.shared.event("render: presentation resumed (\(reason))")
            pacer.resetPresentLag()
        }
    }

    // MARK: Frame intake (render thread)

    private func receive(_ frame: DecodedFrame) {
        if frame.discontinuity { subtitles.reset(); hud.reset() }
        if settings.streamFPS >= 50 && !internet {
            if frame.discontinuity { resetFrameCadence() }
            let thumb = LumaThumbnail(frame.pixelBuffer)
            defer { lastThumbnail = thumb }
            if let thumb, let last = lastThumbnail {
                // Repeats are not bit-identical after compression: compare with the scene's own
                // frame-to-frame change (EMA of the clearly new frames), not a fixed tiny threshold.
                let sad = thumb.sad(last)
                let threshold = max(0.002, min(0.012, 0.3 * newFrameSad))
                if sad > threshold { newFrameSad += (sad - newFrameSad) * 0.1 }
                let discard = repeatedFrameCadence.observe(nearRepeat: sad < threshold)
                let transportFPS = Double(settings.streamFPS)
                setEffectiveFPS(repeatedFrameCadence.isHalfRate ? transportFPS / 2 : transportFPS)
                if discard { return }
            } else if thumb == nil {
                resetFrameCadence()
            }
        }
        accept(frame)
    }

    private func resetFrameCadence() {
        lastThumbnail = nil
        repeatedFrameCadence = RepeatedFrameCadence()
        setEffectiveFPS(Double(settings.streamFPS))
    }

    private func setEffectiveFPS(_ fps: Double) {
        guard fps != effectiveFPS else { return }
        effectiveFPS = fps
        pacer.nominalInterval = 1 / max(1, fps)
        Diagnostics.shared.event(String(format: "render: effective source cadence %.0f fps", fps))
    }

    private func accept(_ frame: DecodedFrame) {
        watchdog.noteFrame(at: CACurrentMediaTime())
        let id = nextID
        nextID += 1
        let prev = previous
        previous = frame
        records[id] = Record(frame: frame)

        let supportsInterpolation = PixelFormats.is8Bit420(frame.pixelBuffer)
        let eligible = supportsInterpolation && displayAllowsGeneration()
        let generating = eligible && llfi?.isReady(for: frame.pixelBuffer) == true
        if !supportsInterpolation {
            setGate("real frames (unsupported pixel format)")
        } else if eligible && !generating {
            setGate(llfi == nil ? "none (Apple ML unavailable)" : "none (Apple ML loading)")
            llfi?.prepare(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        }
        pacer.generatesFrames = generating
        var interp: AppleLLFIInterpolator?
        if generating, let prev, !frame.discontinuity, prev.colourTags == frame.colourTags,
            let llfi, llfi.isReady(for: prev.pixelBuffer)
        {
            setGate(llfi.backendName)
            interp = llfi
        }
        let n = interp != nil ? 1 : 0
        let decoded = HostClock.seconds(frame.decodedHostTime > 0 ? frame.decodedHostTime : HostClock.now())
        pacer.frameArrived(id: id, decodedTime: decoded, generated: n)
        if generating && interp == nil && prev != nil {
            pacer.noteFallback()  // discontinuity / size change / no backend: B repeats
            Diagnostics.shared.setBackend(Source.repeatReal.rawValue, discontinuity: frame.discontinuity, sequence: frame.sequence)
        }
        if let interp, let prev {
            startPair(id: id, previous: prev.pixelBuffer, current: frame.pixelBuffer, interpolator: interp)
        }
        latchHeld()
        prune()
    }

    private func startPair(id: UInt64, previous: CVPixelBuffer, current: CVPixelBuffer, interpolator: AppleLLFIInterpolator) {
        let ep = epoch
        guard let seq = records[id]?.frame.sequence else { return }
        if !settings.sceneCutFallback { records[id]?.cut = false }
        let anchor = pacer.anchor(of: id)

        if settings.sceneCutFallback, let det = cutDetector {
            det.detect(previous: previous, current: current) { [weak self] r in
                self?.perform {
                    guard let self, ep == self.epoch else { return }
                    let cut = r?.isCut ?? false
                    self.records[id]?.cut = cut
                    if cut {
                        self.subtitles.reset()
                        self.hud.reset()
                        Diagnostics.shared.event(String(format: "render: scene cut seq %llu (sad %.3f hist %.3f)", seq, r?.sad ?? 0, r?.histogramDistance ?? 0))
                        self.pacer.midFinished(id: id, ok: false)
                        self.resolveIfWaiting(id)
                    }
                }
            }
        }
        Diagnostics.shared.mark(.interpStart, sequence: seq)
        let sp = Diagnostics.signposter.beginInterval("interpolate", id: Diagnostics.signposter.makeSignpostID())
        interpolator.interpolate(previous: previous, current: current) { [weak self] r in
            self?.perform {
                Diagnostics.signposter.endInterval("interpolate", sp)
                guard let self, ep == self.epoch else { return }
                Diagnostics.shared.mark(.interpEnd, sequence: seq)
                if !r.frames.isEmpty {
                    self.stats.noteInterpolation(ms: r.wallMs)
                    // Budget after the first frames (pipeline compile, clocks).
                    self.interpSamples += 1
                    if self.interpSamples > 10, let anchor { self.pacer.noteReadyOffset(CACurrentMediaTime() - anchor) }
                } else if let e = r.error {
                    Diagnostics.shared.event("render: \(interpolator.backendName) failed seq \(seq): \(e)")
                }
                guard r.frames.count == 1, self.settings.protectSubtitles, let blender = self.blender else {
                    self.midArrived(id: id, buffers: r.frames)
                    return
                }
                let mid = r.frames[0]
                let completion: (CVPixelBuffer?) -> Void = { [weak self] out in
                    self?.perform {
                        guard let self, ep == self.epoch else { return }
                        self.midArrived(id: id, buffers: [out ?? mid])
                    }
                }
                blender.keepSubtitles(previous: previous, current: current, generated: mid,
                    regions: self.subtitles.regions(for: current, at: CACurrentMediaTime()),
                    hudRegions: self.hud.regions(previous: previous, current: current, at: CACurrentMediaTime()), completion: completion)
            }
        }
    }

    private func midArrived(id: UInt64, buffers: [CVPixelBuffer]) {
        guard var rec = records[id], !buffers.isEmpty, rec.mids.isEmpty else { return }
        rec.mids = buffers
        records[id] = rec
        if rec.cut == true { return }
        pacer.midFinished(id: id, ok: true)
        if !resolveIfWaiting(id) { latchHeld() }
    }

    @discardableResult
    private func resolveIfWaiting(_ id: UInt64) -> Bool {
        guard let w = wait, w.id == id else { return false }
        cancelWait()
        handle(pacer.resolveWait(id: id, target: w.target), target: w.target, refresh: w.refresh, deadline: w.deadline, drawable: w.drawable)
        return true
    }

    /// Re-run the decision for the held vsync if its commit deadline is still ahead.
    private func latchHeld() {
        guard let h = held, wait == nil, CACurrentMediaTime() < h.deadline else { return }
        held = nil
        handle(
            pacer.tick(target: h.target, refresh: h.refresh, deadline: h.deadline, recheck: true),
            target: h.target, refresh: h.refresh, deadline: h.deadline, drawable: h.drawable)
    }

    private func prune() {
        let live = Set(pacer.entries.map(\.id))
        for id in records.keys where !live.contains(id) { records[id] = nil }
    }

    // MARK: Display link (render thread)

    func presenter(_ view: MetalPresenterView, tick: DisplayTick) {
        let now = CACurrentMediaTime()
        linkLead.add((tick.targetTime - now) * 1000)
        if let w = wait {
            // The deadline timer did not run before the next vsync: resolve it now.
            waitExpired(id: w.id)
        }
        held = nil
        handleWatchdog(watchdog.noteTick(at: now))
        // Commit deadline for this vsync: just before the next callback (CAMetalDisplayLink runs
        // several refreshes ahead of its target), and never later than target - commit lead.
        let deadline = min(tick.targetTime - pacer.commitLead, CACurrentMediaTime() + tick.refresh - 0.0015)
        if let stall = watchdog.check(now: now) {
            handleWatchdog(stall, target: tick.targetTime, refresh: tick.refresh, drawable: tick.drawable)
            return pushTelemetry(now: now, refresh: tick.refresh)
        }
        handle(
            pacer.tick(target: tick.targetTime, refresh: tick.refresh, deadline: deadline),
            target: tick.targetTime, refresh: tick.refresh, deadline: deadline, drawable: tick.drawable)
        pushTelemetry(now: CACurrentMediaTime(), refresh: tick.refresh)
    }

    func presenterScreenChanged(_ view: MetalPresenterView, display: DisplayInfo?) {
        let hz = display?.refreshHz ?? 60
        let kind = view.linkKind
        Diagnostics.shared.event(
            String(
                format: "render: display %@ (%u) %.2f Hz builtIn=%d link=%@",
                display?.name ?? "none", display?.id ?? 0, hz, display?.isBuiltIn == true ? 1 : 0, kind))
        perform {
            self.displayHz = hz
            self.cancelWait()
            self.held = nil
            self.pacer.resetPresentLag()
        }
    }

    func presenterVisibilityChanged(_ view: MetalPresenterView, visible: Bool) {
        perform {
            let now = CACurrentMediaTime()
            self.handleWatchdog(self.watchdog.noteVisible(visible, at: now))
        }
    }

    private func handle(_ decision: PacerDecision, target: Double, refresh: Double, deadline: Double, drawable: CAMetalDrawable?) {
        switch decision {
        case .hold:
            held = (target, refresh, deadline, drawable)
        case let .real(id, early):
            guard let rec = records[id] else { break }
            if early {
                Diagnostics.shared.setBackend(Source.repeatReal.rawValue, discontinuity: rec.frame.discontinuity, sequence: rec.frame.sequence)
            }
            present(rec.frame.pixelBuffer, generated: false, first: false, frame: rec.frame, drawable: drawable, target: target, refresh: refresh)
        case let .generated(id, index):
            guard let rec = records[id], !rec.mids.isEmpty else { break }
            let mid = rec.mids[min(index, rec.mids.count - 1)]
            if index == 0 {
                Diagnostics.shared.setBackend(Source.appleML.rawValue, sequence: rec.frame.sequence)
            }
            present(mid, generated: true, first: index == 0, frame: rec.frame, drawable: drawable, target: target, refresh: refresh)
        case let .waitForMid(id, _, deadline):
            let timer = thread.schedule(atHostTime: deadline) { [weak self] in self?.waitExpired(id: id) }
            wait = Wait(id: id, target: target, refresh: refresh, deadline: deadline, drawable: drawable, timer: timer)
        }
        prune()
    }

    private func waitExpired(id: UInt64) {
        guard let w = wait, w.id == id else { return }
        cancelWait()
        if let rec = records[id], rec.mids.isEmpty, rec.cut != true {
            Diagnostics.shared.event("render: missed deadline seq \(rec.frame.sequence): nothing generated, real frame shown early")
        }
        handle(pacer.expireWait(id: id, target: w.target), target: w.target, refresh: w.refresh, deadline: w.deadline, drawable: w.drawable)
    }

    private func cancelWait() {
        if let t = wait?.timer { CFRunLoopTimerInvalidate(t) }
        wait = nil
    }

    /// `first`: the pair's first generated frame (its glass time is the frames.csv mid column).
    private func present(
        _ buffer: CVPixelBuffer, generated: Bool, first: Bool, frame: DecodedFrame,
        drawable: CAMetalDrawable?, target: Double, refresh: Double
    ) {
        let stats = self.stats
        let arrival = HostClock.seconds(frame.arrivalHostTime)
        let seq = frame.sequence
        let sp = Diagnostics.signposter.beginInterval("present", id: Diagnostics.signposter.makeSignpostID())
        let ok = view.render(buffer, tags: frame.colourTags, drawable: drawable, targetTime: target, refresh: refresh) { [weak self] presented in
            Diagnostics.signposter.endInterval("present", sp)
            if presented > 0, !generated || first {
                Diagnostics.shared.mark(generated ? .midPresented : .realPresented, sequence: seq, at: HostClock.ticks(seconds: presented))
            }
            stats.notePresented(at: presented, generated: generated, arrival: arrival)
            // Glass time vs target lets the pacer see a backed-up present queue.
            if presented > 0 {
                self?.onFramePresented?(buffer, frame.colourTags, presented)
                if !generated { self?.onVideoPresented?(arrival, presented) }
                self?.perform {
                    guard let self else { return }
                    self.pacer.notePresented(target: target, presented: presented)
                    let now = CACurrentMediaTime()
                    self.handleWatchdog(self.watchdog.noteGlass(at: now))
                }
            }
        }
        if ok {
            let now = CACurrentMediaTime()
            watchdog.noteCommitted(at: now)
            // Handoff lag: frame arrival to handing it to the display.
            if !generated, arrival > 0 { stats.noteHandoff(ms: (now - arrival) * 1000) }
        } else {
            Diagnostics.signposter.endInterval("present", sp)
            stats.noteRenderFailed()
        }
    }

    // MARK: Telemetry

    private func pushTelemetry(now: Double, refresh: Double) {
        guard now - lastTelemetryPush >= 0.25 else { return }
        lastTelemetryPush = now
        let s = stats.snapshot(now: now)
        let c = pacer.counters
        logPhaseSteps(c, snapshot: s, now: now)
        if now - lastLagLog >= 5, s.handoffMean > 0 {
            lastLagLog = now
            Diagnostics.shared.event(
                String(
                    format: "lag: arrival->handoff real mean %.1f p95 %.1f ms | arrival->glass real mean %.1f p95 %.1f, generated p50 %.1f ms",
                    s.handoffMean, s.handoffP95, s.latencyMean, s.latencyP95, s.generatedLatencyP50))
        }
        let label = gateReason
        telemetry.update { t in
            t.displayedFPS = s.displayed
            t.generatedFPS = s.generated
            t.displayHz = refresh > 0 ? 1 / refresh : 0
            t.interpolateMsP50 = s.interpP50
            t.interpolateMsP99 = s.interpP99
            t.arrivalToPresentMsP50 = s.latencyP50
            t.droppedFrames = c.droppedReal + s.unpresented
            t.repeatedFrames = c.repeatedSlots
            t.fallbackFrames = c.skippedMid
            t.interpolationBackend = label
        }
        updateHUD(s, refresh: refresh)
        renderTelemetry.update { $0.realArrivalToPhotonMsP50 = s.latencyP50 }
    }

    private var loggedCounters = PacerCounters()
    private var lastLagLog: Double = 0

    private var loggedDrops: (real: UInt64, unpresented: UInt64, failed: UInt64) = (0, 0, 0)
    private var lastDropLog: Double = 0

    /// Event-log lines for pacer phase steps, queue drains and drops (render thread, <= 4x/s).
    /// Drops are split (pacer evictions vs drawables the compositor dropped vs renders that got
    /// no drawable) with the link's tick period and lead, at most every 5 s.
    private func logPhaseSteps(_ c: PacerCounters, snapshot s: Stats.Snapshot, now: Double) {
        let old = loggedCounters
        loggedCounters = c
        let drops = (c.droppedReal, s.unpresented, s.renderFailed)
        if drops != loggedDrops, now - lastDropLog >= 5 {
            Diagnostics.shared.event(
                String(
                    format:
                        "render: drops real %llu (+%llu) unpresented %llu (+%llu) noDrawable %llu (+%llu) | tick %.2f ms, link lead p50 %.1f ms, hold %d, gen/pair %d",
                    drops.0, drops.0 - loggedDrops.real, drops.1, drops.1 - loggedDrops.unpresented,
                    drops.2, drops.2 - loggedDrops.failed, pacer.refresh * 1000, linkLead.percentile(0.5),
                    pacer.holdSteps, 1))
            loggedDrops = (drops.0, drops.1, drops.2)
            lastDropLog = now
        }
        let ms = pacer.budget * 1000
        if c.phaseEarlier > old.phaseEarlier { Diagnostics.shared.event(String(format: "render: pacer phase one refresh earlier (slack; budget %.1f ms)", ms)) }
        if c.phaseLater > old.phaseLater { Diagnostics.shared.event(String(format: "render: pacer phase later (missed deadlines; budget %.1f ms)", ms)) }
        if c.queueDrains > old.queueDrains {
            Diagnostics.shared.event(
                String(
                    format: "render: present queue backed up (glass - target %.1f ms, usual %.1f ms): one generated frame left out to drain it",
                    pacer.drainLag.lag * 1000, pacer.drainLag.usual * 1000))
        }
    }

    // MARK: HUD (render thread; refreshed with telemetry, <= 4x/s)

    private var lastHUD: Stats.Snapshot?
    private var hudReadingTime: Double = 0
    private var hudOffStreak = 0
    private var lastHUDRefresh: Double = 1.0 / 60

    private var notice: (text: String, until: Double)?

    /// A short message drawn in the HUD corner even when the overlay is off. Any thread.
    func showNotice(_ text: String, seconds: Double) {
        perform {
            self.notice = (text, CACurrentMediaTime() + seconds)
            self.refreshHUD()
        }
    }

    private var activeNotice: HUDLine? {
        guard let notice, CACurrentMediaTime() < notice.until else { return nil }
        return HUDLine(text: notice.text)
    }

    private func refreshHUD() {
        if let s = lastHUD { updateHUD(s, refresh: lastHUDRefresh) } else if !showFPSCounter { view.setHUD(activeNotice.map { [$0] }) }
    }

    private func updateHUD(_ s: Stats.Snapshot, refresh: Double) {
        lastHUD = s
        lastHUDRefresh = refresh
        guard showFPSCounter else { view.setHUD(activeNotice.map { [$0] }); return }
        let shown = Int(s.displayed.rounded()), gen = Int(s.generated.rounded()), real = shown - gen
        let hz = refresh > 0 ? 1 / refresh : 0
        // Expected output: (generated + 1) x source fps while generating (60 or 120), capped by the panel.
        let expected = gateReason.contains("Metal") ? min(hz.rounded(), 2 * effectiveFPS.rounded()) : 60
        // Red only after two consecutive 1-second readings off target (window edges make a
        // single reading of 59 or 61 common even when nothing is wrong).
        let now = CACurrentMediaTime()
        if now - hudReadingTime >= 1 {
            hudReadingTime = now
            let off = s.displayed < expected - 2 || (abs(hz - expected) < 1 && shown != Int(expected))
            hudOffStreak = off ? hudOffStreak + 1 : 0
        }
        let red = hudOffStreak >= 2
        let fps = "\(shown)"
        let backend: String
        if gateReason.hasPrefix("Apple ML") {
            backend = "Apple ML"
        } else if gateReason.contains("Metal") {
            backend = "Metal"
        } else if gateReason.contains("noGeneration60") {
            backend = "real 60"
        } else {
            backend = "none"
        }
        let net = telemetry.snapshot
        var lines = [
            HUDLine(text: "\(fps) FPS  \(real) real + \(gen) gen  \(backend)", red: red ? 0..<fps.count : nil),
            HUDLine(text: "Mac video \(Int(s.latencyP50.rounded())) ms  ML \(Int(s.interpP50.rounded())) ms"),
            HUDLine(text: String(format: "%.0f Mbps  lost %llu", net.bitrateKbps / 1000, net.packetsLost)),
        ]
        if let probe = LatencyProbe.status.text { lines.append(HUDLine(text: probe)) }
        if let notice = activeNotice { lines.append(notice) }
        view.setHUD(lines)
    }

    /// Counters fed from presented handlers (arbitrary threads) and the render thread.
    final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var presented: [(time: Double, generated: Bool)] = []
        private var latency = PercentileWindow(capacity: 120)
        private var handoff = PercentileWindow(capacity: 150)
        private var generatedLatency = PercentileWindow(capacity: 120)
        private var interp = PercentileWindow(capacity: 120)
        private var unpresented: UInt64 = 0, renderFailed: UInt64 = 0

        /// A present that got no drawable (or no command buffer) and was never committed.
        func noteRenderFailed() { lock.withLock { renderFailed += 1 } }

        func notePresented(at time: Double, generated: Bool, arrival: Double?) {
            lock.withLock {
                guard time > 0 else { unpresented += 1; return }
                presented.append((time, generated))
                if presented.count > 1000 { presented.removeFirst(presented.count - 1000) }
                if let arrival, arrival > 0 {
                    if generated { generatedLatency.add((time - arrival) * 1000) } else { latency.add((time - arrival) * 1000) }
                }
            }
        }

        func noteInterpolation(ms: Double) { lock.withLock { interp.add(ms) } }
        func noteHandoff(ms: Double) { lock.withLock { handoff.add(ms) } }

        struct Snapshot {
            var displayed, generated, interpP50, interpP99, latencyP50, generatedLatencyP50: Double
            var handoffMean, handoffP95, latencyMean, latencyP95: Double
            var unpresented, renderFailed: UInt64
        }

        func snapshot(now: Double) -> Snapshot {
            lock.withLock {
                // presentedTime lags the present call: count the last full second ending 50 ms ago.
                let end = now - 0.05, start = end - 1
                let window = presented.filter { $0.time > start && $0.time <= end }
                return Snapshot(
                    displayed: Double(window.count), generated: Double(window.filter(\.generated).count),
                    interpP50: interp.percentile(0.5), interpP99: interp.percentile(0.99),
                    latencyP50: latency.percentile(0.5), generatedLatencyP50: generatedLatency.percentile(0.5),
                    handoffMean: handoff.mean, handoffP95: handoff.percentile(0.95),
                    latencyMean: latency.mean, latencyP95: latency.percentile(0.95),
                    unpresented: unpresented, renderFailed: renderFailed)
            }
        }
    }
}
