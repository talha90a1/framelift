// SPDX-License-Identifier: AGPL-3.0-only
// Wires one stream: session -> decoder -> presentation, audio, controller I/O, window, sleep prevention, retry.
import AppKit
import Combine
import CoreAudio

/// What to stream from.
enum StreamTarget {
    case console(PairedConsole, ConsoleCredentials)

    var title: String {
        switch self {
        case .console(let console, _): console.nickname
        }
    }
}

@MainActor
final class StreamCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case streaming
        case stopping
    }

    struct EndAlert: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    @Published private(set) var phase: Phase = .idle

    /// Called when the stream fully ends (after teardown). `error` is nil for a user-initiated stop.
    var onEnded: ((EndAlert?) -> Void)?
    /// Cmd+Shift+O in the stream window, so the app can persist the choice.
    var onOverlayToggled: ((Bool) -> Void)?

    let input: InputManager

    private var target: StreamTarget?
    private var settings = StreamSettings()
    private var internetProvider: (() async throws -> InternetConnection)?
    private var recorder: StreamRecorder?
    private let recordingOutput = RecordingOutput()
    private let recordingFinishes = DispatchGroup()
    @Published private(set) var isRecording = false
    @Published private(set) var recordingMessage: String?
    private var traceActive = false
    /// "Debug logs", sampled when the stream starts: trace files, core INFO lines, latency probes.
    private(set) var debugLogs = false
    private var statsTimer: Timer?
    private let videoBytes = ByteCounter()
    private var lastStatsTime: UInt64 = 0
    private var timingTicks = 0
    /// Recent seconds with more than 3% packet loss (weak-connection notice, as in chiaki-ng).
    private var lossySeconds: [Bool] = []
    private var lastWeakNotice: UInt64 = 0
    private var window: StreamWindowController?
    private var engine: PresentationEngine?
    private var latencyProbe: LatencyProbe?
    private var source: RemotePlaySession?
    private var audio: AudioOutput?
    private var activity: NSObjectProtocol?
    /// Bumped per session instance so late events from a replaced or stopped session are ignored.
    private var generation = 0
    private var retriesLeft = SessionRetryPolicy.maxRetries
    private var retryResetWork: DispatchWorkItem?
    private var connectionTimeout: Task<Void, Never>?
    private var recordingGeneration = 0
    private var firstFrameTimeout: Task<Void, Never>?
    private var attemptConnected = false
    private var attemptHasVideo = false
    /// When the last stream from this Mac ended: a PS5 "in use" soon after most likely means that session.
    private var lastStreamEnd: UInt64?
    /// A stream that stays up this long earns its automatic retries back.
    private static let stableAfter: TimeInterval = 30
    private static let recentEnd: TimeInterval = 30

    init(input: InputManager) {
        self.input = input
    }

    var isActive: Bool { phase != .idle }
    var hasPendingRecordings: Bool { isRecording || recordingFinishes.wait(timeout: .now()) == .timedOut }

    // MARK: Start / stop

    func start(_ target: StreamTarget, settings: StreamSettings, internetProvider: (() async throws -> InternetConnection)? = nil) {
        guard phase == .idle else { return }
        self.target = target
        self.settings = settings
        self.internetProvider = internetProvider
        debugLogs = DebugLogs.stored()
        retriesLeft = SessionRetryPolicy.maxRetries
        phase = .connecting("Connecting to \(target.title)…")
        let startedAt = Date()
        beginTrace(startedAt: startedAt)
        if VideoRecording.stored() {
            let name = LogFolders.sessionName(label: "ps5", date: startedAt)
            recorder = StreamRecorder(directory: VideoRecording.root.appendingPathComponent(name, isDirectory: true))
        }

        let window = StreamWindowController(
            settings: settings, title: target.title, debugTools: debugLogs,
            loginParent: NSApp.keyWindow ?? NSApp.mainWindow)
        window.delegate = self
        self.window = window
        let engine = PresentationEngine(view: window.presenterView, settings: settings)
        self.engine = engine
        let recording = recordingOutput
        engine.onFramePresented = { buffer, tags, time in recording.video(buffer, tags: tags, at: time) }
        recording.onError = { [weak self] message in
            Self.onMain {
                self?.reportRecording(message)
                self?.stopRecording()
            }
        }
        engine.showFPSCounter = settings.showOverlay

        let audio = AudioOutput()
        audio.setOffset(milliseconds: settings.audioOffsetMs)
        engine.onVideoPresented = { [weak audio] arrival, presented in audio?.noteVideoPresentation(arrival: arrival, presented: presented) }
        audio.start()
        self.audio = audio

        logEnvironment()
        startStatsTimer()
        startSource()
    }

    private func endTrace() {
        guard traceActive else { return }
        traceActive = false
        Diagnostics.shared.endSession()
        Diagnostics.shared.enabled = false
    }

    /// Folder of the current (or last) trace.
    var traceDirectory: URL? { Diagnostics.shared.directory }

    /// User-initiated leave (Esc, Cmd+Shift+Q, menu, window close). No alert, no retry.
    func stop(completion: (() -> Void)? = nil) {
        teardown(alert: nil, completion: completion)
    }

    /// Live-applicable settings (scene-cut fallback, overlay, static-overlay guard, blend fallback).
    /// Keep-warm applies on the next stream; resolution/fps/codec/bitrate are negotiated with the PS5
    /// at session start and apply on the next connect.
    func applyLive(_ newSettings: StreamSettings) {
        guard isActive else { return }
        settings.sceneCutFallback = newSettings.sceneCutFallback
        settings.showOverlay = newSettings.showOverlay
        settings.keepStaticOverlays = newSettings.keepStaticOverlays
        settings.protectSubtitles = newSettings.protectSubtitles
        settings.audioOffsetMs = newSettings.audioOffsetMs
        audio?.setOffset(milliseconds: newSettings.audioOffsetMs)
        settings.blendFallback = newSettings.blendFallback
        settings.sharpness = newSettings.sharpness
        settings.upscaler = newSettings.upscaler
        engine?.update(settings: settings)
        window?.overlayVisible = newSettings.showOverlay
        engine?.showFPSCounter = newSettings.showOverlay
        Diagnostics.shared.event(
            "live settings frameGeneration=always subtitles=\(settings.protectSubtitles) sceneCutFallback=\(settings.sceneCutFallback) keepStatic=\(settings.keepStaticOverlays) blendFallback=\(settings.blendFallback) sharpness=\(settings.sharpness) upscaler=\(settings.upscaler.rawValue)"
        )
    }

    // MARK: Pipeline

    private func startSource() {
        audio?.resetSync()
        guard case .console(let console, let credentials) = target, let engine else { return }
        generation += 1
        let generation = generation
        attemptConnected = false
        attemptHasVideo = false
        videoBytes.reset()

        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.internetProvider == nil ? 30 : 90)) } catch { return }
            guard let self, generation == self.generation, case .connecting = self.phase else { return }
            self.teardown(alert: EndAlert(title: "Connection timed out", message: "The PS5 did not finish connecting. Check that it is online and Remote Play is enabled."), completion: nil)
        }
        Task { [weak self] in
            do {
                let internet = try await self?.internetProvider?()
                guard let self, generation == self.generation, self.isActive, self.phase != .stopping else { return }
                self.startResolvedSource(console, credentials: credentials, engine: engine, internet: internet, generation: generation)
            } catch {
                guard let self, generation == self.generation else { return }
                self.teardown(alert: EndAlert(title: "Couldn't connect", message: error.localizedDescription), completion: nil)
            }
        }
    }

    private func startResolvedSource(_ console: PairedConsole, credentials: ConsoleCredentials, engine: PresentationEngine,
                                     internet: InternetConnection?, generation: Int) {
        let session = RemotePlaySession(host: console.host, credentials: credentials, settings: settings, internet: internet)
        session.onEvent = { [weak self] event in
            Self.onMain { self?.handle(event, generation: generation) }
        }
        // InputManager.apply hands off to its own queue, so it is safe on the core thread.
        session.onFeedback = { [weak input] feedback in input?.apply(feedback) }
        let frameSink: FrameSink
        if debugLogs {
            let probe = LatencyProbe(controller: session, frames: engine)
            latencyProbe = probe
            input.sink = probe
            frameSink = probe
        } else {
            latencyProbe = nil
            input.sink = session
            frameSink = engine
        }

        let decoder = VideoDecoder(
            sink: frameSink,
            onNeedKeyframe: { [weak session] in
                Diagnostics.shared.event("keyframe requested by decoder")
                session?.requestKeyframe()
            },
            onFirstFrame: { [weak self] in
                Self.onMain {
                    guard let self, generation == self.generation, case .connecting = self.phase else { return }
                    self.attemptHasVideo = true
                    self.showStreamIfReady()
                }
            })
        let bytes = videoBytes
        let recorder = recorder
        session.onVideo = { unit in
            bytes.add(unit.data.count)
            let started = HostClock.now()
            recorder?.append(unit)
            let recorded = HostClock.now()
            decoder.decode(unit)
            let finished = HostClock.now()
            if HostClock.milliseconds(from: started, to: finished) > 20 {
                Diagnostics.shared.event(String(format: "video callback slow: source-recording=%.2fms decoder-call=%.2fms bytes=%d",
                                                HostClock.milliseconds(from: started, to: recorded),
                                                HostClock.milliseconds(from: recorded, to: finished), unit.data.count))
            }
        }
        let audio = audio
        let recording = recordingOutput
        session.onAudio = { chunk in
            audio?.enqueue(chunk)
            recording.audio(chunk, delayMs: audio?.presentationDelayMs ?? 40)
        }
        source = session

        do {
            try session.start()
        } catch {
            sessionEnded(
                transient: true,
                alert: EndAlert(title: "Couldn't start the stream", message: error.localizedDescription),
                generation: generation
            )
        }
    }

    private func handle(_ event: SessionEvent, generation: Int) {
        guard generation == self.generation, isActive, phase != .stopping else { return }
        Diagnostics.shared.event("session event \(Self.describe(event))")
        switch event {
        case .connectionProgress(let stage):
            let message = switch stage {
            case 1: "Connecting to PlayStation…"
            case 2: "Contacting your PS5…"
            default: "Connecting through your router…"
            }
            phase = .connecting(message)
        case .connected:
            guard !attemptConnected else { return }
            attemptConnected = true
            if attemptHasVideo {
                showStreamIfReady()
            } else {
                phase = .connecting("Waiting for video…")
                firstFrameTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard let self, generation == self.generation, case .connecting = self.phase else { return }
                    self.teardown(
                        alert: EndAlert(title: "No video from the PS5", message: "The PS5 connected, but no playable video arrived."),
                        completion: nil
                    )
                }
            }
        case .loginPinRequired:
            window?.promptForLoginPin { [weak self] pin in
                guard let self, generation == self.generation, let session = self.source else { return }
                if let pin, !pin.isEmpty { session.submitLoginPin(pin) } else { self.stop() }
            }
        case .quit(let reason, let message):
            let recentlyEnded =
                lastStreamEnd.map {
                    HostClock.seconds(HostClock.now() - $0) < Self.recentEnd
                } ?? false
            let ourSessionLikely = retriesLeft < SessionRetryPolicy.maxRetries || recentlyEnded
            sessionEnded(
                transient: SessionRetryPolicy.isTransient(quitReason: reason, ourSessionLikely: ourSessionLikely),
                consoleHoldsSession: SessionRetryPolicy.consoleHoldsSession(quitReason: reason),
                alert: EndAlert(
                    title: window?.hasShown == true ? "Stream ended" : "Connection failed",
                    message: message.isEmpty ? SessionMessages.quitMessage(reason: reason) : message
                ),
                generation: generation
            )
        case .failed(let code, let message):
            sessionEnded(
                transient: SessionRetryPolicy.isTransient(failureCode: code),
                alert: EndAlert(
                    title: "Connection failed",
                    message: message.isEmpty ? "Error \(code)." : "\(message) (error \(code))"
                ),
                generation: generation
            )
        }
    }

    private func showStreamIfReady() {
        guard attemptConnected, attemptHasVideo, let window else { return }
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        phase = .streaming
        beginDisplayActivity()
        window.show()
        scheduleRetryReset()
    }

    private func sessionEnded(transient: Bool, consoleHoldsSession: Bool = false, alert: EndAlert, generation: Int) {
        guard generation == self.generation, isActive, phase != .stopping else { return }
        guard transient, retriesLeft > 0 else {
            teardown(alert: alert, completion: nil)
            return
        }
        let retry = SessionRetryPolicy.maxRetries - retriesLeft + 1
        retriesLeft -= 1
        retryResetWork?.cancel()
        connectionTimeout?.cancel()
        connectionTimeout = nil
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        let wait = SessionRetryPolicy.wait(consoleHoldsSession: consoleHoldsSession, wasPlaying: attemptConnected)
        let delay = SessionRetryPolicy.seconds(wait, retry: retry)
        let count = "\(retry)/\(SessionRetryPolicy.maxRetries)"
        Diagnostics.shared.event("transient failure, reconnecting in \(Int(delay)) s (\(wait), \(count)): \(alert.message)")
        let status =
            switch wait {
            case .start: "Retrying connection (\(count))…"
            case .inUse: "PS5 still in use. Retrying in \(Int(delay)) s (\(count))…"
            case .afterLive: "Connection lost. Retrying in \(Int(delay)) s (\(count))…"
            }
        phase = .connecting(status)
        engine?.showNotice(status, seconds: max(delay + 3, 6))
        self.generation += 1  // silence the dying session
        window?.dismissLoginPrompt()
        let waiting = self.generation
        let old = source
        source = nil
        input.sink = nil
        latencyProbe?.stop()
        if let hidStats = input.resetFeedback() { Diagnostics.shared.event("dualsense hid: \(hidStats)") }
        latencyProbe = nil
        LatencyProbe.status.set(nil)
        Self.offMain({ old?.stop() }) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == waiting, case .connecting = self.phase else { return }
                self.engine?.reset()
                self.startSource()
            }
        }
    }

    private func scheduleRetryReset() {
        retryResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retriesLeft = SessionRetryPolicy.maxRetries }
        retryResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stableAfter, execute: work)
    }

    private func teardown(alert: EndAlert?, completion: (() -> Void)?) {
        stopRecording()
        guard isActive, phase != .stopping else {
            completion?()
            return
        }
        phase = .stopping
        generation += 1
        lastStreamEnd = HostClock.now()
        retryResetWork?.cancel()
        connectionTimeout?.cancel()
        connectionTimeout = nil
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        input.sink = nil
        latencyProbe?.stop()
        if let hidStats = input.resetFeedback() { Diagnostics.shared.event("dualsense hid: \(hidStats)") }
        latencyProbe = nil
        LatencyProbe.status.set(nil)
        statsTimer?.invalidate()
        statsTimer = nil
        Diagnostics.shared.event(alert.map { "stream ended: \($0.title): \($0.message)" } ?? "stream stopped by user")

        let source = source
        let audio = audio
        let engine = engine
        let recorder = recorder
        let recordingFinishes = recordingFinishes
        self.source = nil
        self.audio = nil
        self.recorder = nil
        window?.close()
        window = nil
        endDisplayActivity()

        Self.offMain({
            source?.stop()
            recorder?.finish()
            audio?.stop()
            recordingFinishes.wait()
        }) { [weak self] in
            // The engine outlives the source so in-flight decoder output still has a sink.
            engine?.reset()
            if let self {
                self.endTrace()
                self.engine = nil
                self.target = nil
                self.internetProvider = nil
                self.phase = .idle
                self.onEnded?(alert)
            }
            completion?()
        }
    }

    // MARK: Diagnostics

    private func beginTrace(startedAt: Date) {
        endTrace()
        Diagnostics.shared.enabled = debugLogs
        guard debugLogs else { return }
        Diagnostics.shared.beginSession(
            label: "ps5", date: startedAt,
            header: SystemReport.make(
                settings: settings, controller: input.controllerName, controllerFeedback: input.feedbackSummary))
        traceActive = true
        Diagnostics.shared.event("presentation timestamps are actual drawable times; blank CSV presentation fields mean not presented")
        Diagnostics.shared.event("CSV decode_ms measures arrival to decoded output, including queueing and source recording; it is not decoder-call duration")
    }

    /// Chosen settings and environment. Never logs credentials or the account id.
    private func logEnvironment() {
        let d = Diagnostics.shared
        let s = settings
        if case .console(let console, _) = target {
            d.event("target ps5 \(console.nickname) host=\(console.host)")
            d.event("console link: \(SystemReport.consoleLink(host: console.host))")
        }
        d.event(
            "settings \(s.width)x\(s.height)@\(s.streamFPS) bitrate=\(s.bitrateKbps)kbps codec=\(s.codec.label) fullscreen=\(s.fullscreen) sceneCutFallback=\(s.sceneCutFallback) sharpness=\(s.sharpness)"
        )
        d.event(
            "frame generation enabled=always subtitles=\(s.protectSubtitles) keepWarm=\(s.keepLLFIWarm) keepStatic=\(s.keepStaticOverlays) blendFallback=\(s.blendFallback) buffers=\(DisplayBuffering.stored().drawableCount)"
        )
        if let screen = window?.screen {
            d.event("display \(screen.localizedName) \(DisplayInfo.hzText(Double(screen.maximumFramesPerSecond))) Hz frame=\(screen.frame)")
        }
        d.event("audio output \(Self.defaultOutputDeviceName() ?? "unknown")")
        d.event("controller \(input.controllerName ?? "none")")
        d.event("controller feedback \(input.feedbackSummary) (setting: \(DualSenseFeedbackMode.stored().title))")
    }

    /// Once a second: measured video bitrate and transport stats into Telemetry and the trace.
    private func startStatsTimer() {
        statsTimer?.invalidate()
        lastStatsTime = HostClock.now()
        _ = videoBytes.take()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statsTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func statsTick() {
        let now = HostClock.now()
        let elapsed = max(HostClock.seconds(now - lastStatsTime), 0.001)
        lastStatsTime = now
        let kbps = Double(videoBytes.take()) * 8 / 1000 / elapsed
        Telemetry.shared.update { $0.bitrateKbps = kbps }
        guard let session = source else { return }
        if attemptConnected, attemptHasVideo, StreamHealth.videoTimedOut(lastArrival: videoBytes.lastArrival, now: now) {
            sessionEnded(transient: true, alert: EndAlert(title: "Connection lost", message: "No video has arrived from the PS5 for five seconds. Reconnect after checking the console and network."), generation: generation)
            return
        }
        if debugLogs { Diagnostics.shared.event(audio?.diagnostics ?? "audio output unavailable") }
        timingTicks += 1
        if debugLogs, timingTicks % 5 == 0 { Diagnostics.shared.event(input.takeTimingSummary()) }
        let stats = session.stats
        Telemetry.shared.update { $0.packetsLost = stats.packets_lost }
        noteLoss(received: stats.packets_received, lost: stats.packets_lost, now: now)
        Diagnostics.shared.event(
            String(
                format: "session stats connected=%d kbps=%.0f target_kbps=%lld received=%llu lost=%llu idr=%llu warnings=%llu errors=%llu",
                stats.connected ? 1 : 0, kbps, stats.server_target_bitrate, stats.packets_received, stats.packets_lost,
                stats.idr_requests, stats.warnings, stats.errors
            ))
    }

    /// Three lossy seconds out of the last five shows a short notice, at most once a minute.
    private func noteLoss(received: UInt64, lost: UInt64, now: UInt64) {
        let total = received + lost
        lossySeconds.append(total > 50 && Double(lost) / Double(total) > 0.03)
        if lossySeconds.count > 5 { lossySeconds.removeFirst() }
        guard lossySeconds.filter({ $0 }).count >= 3,
            lastWeakNotice == 0 || HostClock.seconds(now - lastWeakNotice) > 60
        else { return }
        lastWeakNotice = now
        lossySeconds.removeAll()
        Diagnostics.shared.event("weak connection notice")
        engine?.showNotice("Weak connection: lower Bitrate in Settings or use a cable", seconds: 6)
    }

    private static func describe(_ event: SessionEvent) -> String {
        switch event {
        case .connectionProgress(let stage): "connection progress \(stage)"
        case .connected: "connected"
        case .loginPinRequired: "login PIN required"
        case .quit(let reason, let message): "quit reason=\(reason) \(message)"
        case .failed(let code, let message): "failed code=\(code) \(message)"
        }
    }

    private static func defaultOutputDeviceName() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    // MARK: Display sleep

    /// Controller input doesn't reset the idle timer, so without this the TV/panel would sleep mid-game.
    private func beginDisplayActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
            reason: "Streaming from PlayStation"
        )
    }

    private func endDisplayActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Helpers

    /// Runs blocking work (session/source joins) on a background queue, then `then` on main.
    /// The pipeline objects are handed across threads deliberately: their stop()s are documented as
    /// callable off main, which is the only thing done with them there.
    nonisolated private static func offMain(_ work: @escaping () -> Void, then: @escaping @MainActor () -> Void) {
        let box = UncheckedSendable((work, then))
        DispatchQueue.global(qos: .userInitiated).async {
            box.value.0()
            DispatchQueue.main.async { MainActor.assumeIsolated(box.value.1) }
        }
    }

    /// Session events are documented as main-queue, but don't crash if a backend delivers elsewhere.
    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

extension StreamCoordinator: StreamWindowDelegate {
    func streamWindowRequestedLeave() { stop() }

    func streamWindowToggledOverlay(_ visible: Bool) {
        settings.showOverlay = visible
        engine?.showFPSCounter = visible
        onOverlayToggled?(visible)
    }

    func streamWindowToggledLatencyProbe() {
        guard let latencyProbe else { return }  // only with debug logs on
        latencyProbe.toggle()
    }

    func toggleRecording() {
        if isRecording { stopRecording(); return }
        guard phase == .streaming else { return }
        recordingGeneration += 1
        let name = Self.mediaName() + ".mp4"
        recordingOutput.start(url: VideoRecording.root.appendingPathComponent(name))
        isRecording = true
        recordingMessage = nil
        engine?.showNotice("Recording started", seconds: 2)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let generation = recordingGeneration
        let finishes = recordingFinishes
        finishes.enter()
        recordingOutput.stop { [weak self] result in
            defer { finishes.leave() }
            Self.onMain {
                guard let self, generation == self.recordingGeneration else { return }
                switch result {
                case .success(let url): self.reportRecording("Saved \(url.lastPathComponent)")
                case .failure(let error): self.reportRecording(error.localizedDescription)
                }
            }
        }
    }

    func saveScreenshot() {
        guard phase == .streaming else { return }
        let url = VideoRecording.root.appendingPathComponent(Self.mediaName() + ".png")
        let output = recordingOutput
        Task {
            let result = await BridgeInterop.run { Result { try output.screenshot(to: url) } }
            switch result {
            case .success: reportRecording("Saved \(url.lastPathComponent)")
            case .failure(let error): reportRecording(error.localizedDescription)
            }
        }
    }

    private func reportRecording(_ message: String) {
        recordingMessage = message
        engine?.showNotice(message.hasPrefix("Saved ") ? "Saved in Movies/Framelift" : message, seconds: 5)
    }

    private static func mediaName() -> String {
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return date + "-" + UUID().uuidString.prefix(6)
    }

}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Video bytes received since the last stats tick (written on the source thread, read on main).
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var arrival: UInt64 = 0

    var lastArrival: UInt64 { lock.withLock { arrival } }

    func reset() { lock.withLock { bytes = 0; arrival = HostClock.now() } }

    func add(_ count: Int) {
        lock.lock(); bytes += count; arrival = HostClock.now(); lock.unlock()
    }

    func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let value = bytes
        bytes = 0
        return value
    }
}

enum StreamHealth {
    static func videoTimedOut(lastArrival: UInt64, now: UInt64) -> Bool {
        lastArrival > 0 && now >= lastArrival && HostClock.seconds(now - lastArrival) >= 5
    }
}
