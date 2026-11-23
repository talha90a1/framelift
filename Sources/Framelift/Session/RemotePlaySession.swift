// SPDX-License-Identifier: AGPL-3.0-only
// One PS5 Remote Play session over the VeyraCore bridge (Veyra's ChiakiBackend on chiaki-ng).
import Foundation
import VeyraCore

struct RemotePlaySessionError: LocalizedError {
    var code: Int32
    var errorDescription: String? { SessionMessages.errorMessage(code: code) }
}

final class RemotePlaySession: ControllerSink {
    /// Called on the core's session thread with each Annex-B access unit (or codec config).
    var onVideo: ((EncodedVideoUnit) -> Void)?
    /// Called on the core's session thread.
    var onAudio: ((PCMChunk) -> Void)?
    /// Delivered on the main queue.
    var onEvent: ((SessionEvent) -> Void)?
    /// Called on the core's session thread.
    var onFeedback: ((ControllerFeedbackEvent) -> Void)?

    private let host: String
    private let credentials: ConsoleCredentials
    private let settings: StreamSettings
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var box: Unmanaged<CallbackBox>?
    private var diagnosticsTimer: DispatchSourceTimer?

    /// Retained across the C boundary as the callbacks' `user`; released only after vr_session_stop joined.
    private final class CallbackBox {
        weak var session: RemotePlaySession?
        let codec: VideoCodecKind
        init(session: RemotePlaySession, codec: VideoCodecKind) {
            self.session = session
            self.codec = codec
        }
    }

    init(host: String, credentials: ConsoleCredentials, settings: StreamSettings) {
        self.host = host
        self.credentials = credentials
        self.settings = settings
    }

    /// The last reference may drop inside a core callback (which holds a temporary strong ref);
    /// stopping inline would make the session thread join itself, so stop on a GCD worker.
    deinit {
        diagnosticsTimer?.cancel()
        guard let handle else { return }
        let box = self.box
        nonisolated(unsafe) let session = handle
        DispatchQueue.global(qos: .userInitiated).async {
            vr_session_stop(session)
            box?.release()
        }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        guard credentials.isValid else { throw RemotePlaySessionError(code: -2001) }
        let initResult = BridgeInterop.initResult
        guard initResult == 0 else { throw RemotePlaySessionError(code: initResult) }
        CoreDiagnostics.installLogForwarding()

        var profile = VRVideoProfile()
        profile.width = settings.width
        profile.height = settings.height
        profile.fps = settings.streamFPS
        profile.bitrate_kbps = settings.bitrateKbps
        profile.codec = switch settings.codec {
        case .h264: VR_CODEC_H264
        case .hevc: VR_CODEC_H265
        case .hevcHDR: VR_CODEC_H265_HDR
        }

        let box = Unmanaged.passRetained(CallbackBox(session: self, codec: settings.codec))
        var callbacks = VRCallbacks()
        callbacks.user = box.toOpaque()
        callbacks.video = Self.videoCallback
        callbacks.audio = Self.audioCallback
        callbacks.event = Self.eventCallback
        callbacks.triggers = Self.triggersCallback
        callbacks.haptics = Self.hapticsCallback

        var cCredentials = BridgeInterop.credentials(credentials)
        defer { BridgeInterop.wipe(&cCredentials) }
        var error: Int32 = 0
        guard let session = vr_session_start(host, &cCredentials, &profile, &callbacks, &error) else {
            box.release()
            throw RemotePlaySessionError(code: error != 0 ? error : -2002)
        }
        handle = session
        self.box = box
        if Diagnostics.shared.enabled { startDiagnosticsTimer() }
    }

    /// Once per second while streaming: one "core ..." line into Diagnostics.shared.
    private func startDiagnosticsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let d = self?.diagnostics, CoreDiagnostics.isStreaming(d) else { return }
            Diagnostics.shared.event(CoreDiagnostics.line(d))
        }
        timer.resume()
        diagnosticsTimer = timer
    }

    /// Stops and joins the core session. Blocks briefly: call off the main thread when possible.
    func stop() {
        lock.lock()
        let session = handle
        let box = self.box
        let timer = diagnosticsTimer
        handle = nil
        self.box = nil
        diagnosticsTimer = nil
        lock.unlock()
        timer?.cancel()
        guard let session else { return }
        if Diagnostics.shared.enabled {
            let finalLine = CoreDiagnostics.line(vr_session_diagnostics(session))
                .replacingOccurrences(of: "core ", with: "core final ", options: .anchored)
            Diagnostics.shared.event(finalLine)
        }
        vr_session_stop(session)
        box?.release()
    }

    func submitLoginPin(_ pin: String) {
        withHandle { _ = vr_session_set_login_pin($0, pin) }
    }

    /// Ask the console for a new IDR (decoder error / lost references).
    func requestKeyframe() {
        withHandle { _ = vr_session_request_idr($0) }
    }

    func send(_ state: ControllerSnapshot) {
        var c = VRControllerState()
        c.buttons = state.buttons.rawValue
        c.left_x = state.leftX
        c.left_y = state.leftY
        c.right_x = state.rightX
        c.right_y = state.rightY
        c.l2 = state.l2
        c.r2 = state.r2
        let first = state.touches.first ?? .init()
        let second = state.touches.count > 1 ? state.touches[1] : .init()
        c.touches.0 = VRTouch(id: first.id, x: first.x, y: first.y)
        c.touches.1 = VRTouch(id: second.id, x: second.x, y: second.y)
        c.motion_valid = state.motionValid
        c.gyro = (state.gyro.x, state.gyro.y, state.gyro.z)
        c.accel = (state.accel.x, state.accel.y, state.accel.z)
        c.motion_timestamp_us = state.motionTimestampUs
        withHandle { _ = vr_session_set_controller($0, &c) }
    }

    /// Full core telemetry (Veyra queues, chiaki packet/FEC counters, delivery latency); refreshed every 100 ms.
    var diagnostics: VRDiagnostics {
        var result = VRDiagnostics()
        withHandle { result = vr_session_diagnostics($0) }
        return result
    }

    var stats: VRStats {
        var result = VRStats()
        withHandle { result = vr_session_stats($0) }
        return result
    }

    /// Runs `body` with the live handle while holding the lock, so stop() can't free it underneath.
    /// The bridge calls used here only post to the core and return immediately.
    private func withHandle(_ body: (OpaquePointer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let handle { body(handle) }
    }

    // MARK: - C callbacks (core session thread)

    private static func session(_ user: UnsafeMutableRawPointer?) -> (CallbackBox, RemotePlaySession)? {
        guard let user else { return nil }
        let box = Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue()
        guard let session = box.session else { return nil }
        return (box, session)
    }

    private static let videoCallback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, Bool, UInt32, UInt32, Int32, Bool, UInt64
    ) -> Void = { user, bytes, size, _, _, _, framesLost, recovered, arrival in
        guard let (box, session) = session(user), let bytes, size > 0, let onVideo = session.onVideo else { return }
        onVideo(EncodedVideoUnit(
            data: Data(bytes: bytes, count: size),
            codec: box.codec,
            framesLost: framesLost,
            recovered: recovered,
            arrivalHostTime: arrival
        ))
    }

    private static let audioCallback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<Int16>?, Int, UInt32, UInt32
    ) -> Void = { user, pcm, frames, channels, rate in
        guard let (_, session) = session(user), let pcm, frames > 0, channels > 0,
              let onAudio = session.onAudio else { return }
        let samples = Array(UnsafeBufferPointer(start: pcm, count: frames * Int(channels)))
        onAudio(PCMChunk(samples: samples, channels: channels, sampleRate: rate))
    }

    private static let eventCallback: @convention(c) (
        UnsafeMutableRawPointer?, VREventType, Int32, Int32, Int32
    ) -> Void = { user, type, code, a, b in
        guard let (_, session) = session(user) else { return }
        let event: SessionEvent
        switch type {
        case VR_EVENT_RUMBLE:
            session.onFeedback?(.rumble(left: UInt8(clamping: a), right: UInt8(clamping: b)))
            return
        case VR_EVENT_MOTION_RESET:
            session.onFeedback?(.motionReset)
            return
        case VR_EVENT_CONNECTED:
            event = .connected
        case VR_EVENT_LOGIN_PIN_REQUEST:
            event = .loginPinRequired
        case VR_EVENT_QUIT:
            event = .quit(reason: code, message: SessionMessages.quitMessage(reason: code))
        case VR_EVENT_FAILED:
            event = .failed(code: code, message: SessionMessages.errorMessage(code: code))
        default:
            return
        }
        DispatchQueue.main.async { [weak session] in session?.onEvent?(event) }
    }

    private static let triggersCallback: @convention(c) (
        UnsafeMutableRawPointer?, UInt8, UnsafePointer<UInt8>?, UInt8, UnsafePointer<UInt8>?
    ) -> Void = { user, typeLeft, left, typeRight, right in
        guard let (_, session) = session(user), let left, let right, let onFeedback = session.onFeedback else { return }
        onFeedback(.triggers(
            typeLeft: typeLeft,
            left: Array(UnsafeBufferPointer(start: left, count: 10)),
            typeRight: typeRight,
            right: Array(UnsafeBufferPointer(start: right, count: 10))
        ))
    }

    private static let hapticsCallback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<Int16>?, Int
    ) -> Void = { user, pcm, frames in
        guard let (_, session) = session(user), let pcm, frames > 0, let onFeedback = session.onFeedback else { return }
        onFeedback(.haptics(Array(UnsafeBufferPointer(start: pcm, count: frames * 2))))
    }
}
