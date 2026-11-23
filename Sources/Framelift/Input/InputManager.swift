// SPDX-License-Identifier: AGPL-3.0-only
// Controller input (GameController, keyboard/mouse fallback) → ControllerSnapshot, sent on every change
// and at `tickHz` as keepalive; PS5 feedback → controller (DualSense raw HID in Exact mode, else CoreHaptics).
import AppKit
import Combine
import Foundation
import GameController

final class InputManager: ObservableObject, @unchecked Sendable {
    @Published private(set) var controllerName: String?

    var sink: ControllerSink? {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return _sink }
        set { sinkLock.lock(); _sink = newValue; sinkLock.unlock() }
    }

    static let tickHz: Double = 200
    static let mouseGain: Double = 1500       // stick units per mouse point per event
    static let mouseHoldSeconds: Double = 0.03
    static let hapticsHoldSeconds: Double = 0.06
    /// Exact mode: console rumble is held back while PCM haptics arrived this recently.
    static let pcmActiveSeconds: Double = 0.25
    /// GameController may rewrite the pad's state when the app becomes active; re-apply after it.
    static let activationReapplySeconds: Double = 0.3

    private let sinkLock = NSLock()
    private var _sink: ControllerSink?
    private let queue = DispatchQueue(label: "framelift.input", qos: .userInteractive)

    // Everything below is owned by `queue`.
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var controller: GCController?
    private var haptics: ControllerHaptics?
    /// Exact-mode raw HID output for the attached DualSense; nil in Compatible mode or after fallback.
    private var dualSense: DualSenseOutput?
    /// Exact mode: a trigger write failed, so triggers use GameController (haptics stay on HID).
    private var hidTriggersFailed = false
    /// The setting the current controller was attached with; a change re-attaches it.
    private var attachedFeedbackMode = DualSenseFeedbackMode.exact
    private let summaryLock = NSLock()
    private var _feedbackSummary = "none"
    private var lastSent: ControllerSnapshot?

    private struct TouchSlot { var down = false; var id: Int8 = -1 }
    private var touchSlots = [TouchSlot(), TouchSlot()]
    private var nextTouchID: Int8 = 0
    /// L2/R2 jitter filter (TriggerFilter.swift), so a trigger release is not pushed out of chiaki's
    /// 8-event feedback history. Reset whenever the controller changes or input stops.
    private var triggerFilter = TriggerFilter()

    private var rumble: (l: Float, r: Float) = (0, 0)
    private var hapticLevel: (l: Float, r: Float) = (0, 0)
    /// Last trigger effect from the console. GameController ignores trigger modes while the app is
    /// inactive, so it is re-applied whenever the app becomes active again.
    private var lastTriggers: (typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8])?
    private var lastHapticsHostTime: UInt64 = 0

    private struct KeyboardState {
        var keys = Set<UInt16>()
        var leftMouse = false
        var rightMouse = false
        var mouseDelta = SIMD2<Double>(0, 0)
        var mouseHostTime: UInt64 = 0
    }
    private var keyboard = KeyboardState()
    /// Main-thread mirror of "a controller is connected", for the synchronous `handle(event:)` answer.
    private var controllerConnectedMain = false

    init() {}

    deinit { timer?.cancel() }

    // MARK: Lifecycle

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        queue.async { [self] in
            guard !running else { return }
            running = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.selectController() }
            })
            observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] note in
                let gone = note.object as? GCController
                self?.queue.async { self?.controllerDisconnected(gone) }
            })
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.applyLastTriggers(force: true) }
                self?.queue.asyncAfter(deadline: .now() + Self.activationReapplySeconds) { self?.applyLastTriggers(force: true) }
            })
            observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.feedbackSettingMaybeChanged() }
            })
            selectController()

            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = 1.0 / Self.tickHz
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync { [self] in
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            detachController(clearFeedback: true, closeWait: 0.1)
            lastTriggers = nil
            keyboard = KeyboardState()
            triggerFilter.reset()
            send(ControllerSnapshot(), force: true) // leave the PS5 with a neutral pad
            lastSent = nil
        }
    }

    // MARK: Controller selection

    private func rank(_ c: GCController) -> Int {
        guard let pad = c.extendedGamepad else { return 0 }
        if pad is GCDualSenseGamepad { return 4 }
        if pad is GCDualShockGamepad { return 3 }
        if pad is GCXboxGamepad { return 2 }
        return 1
    }

    private func selectController() {
        guard running else { return }
        let best = GCController.controllers()
            .filter { $0.extendedGamepad != nil }
            .max { rank($0) < rank($1) }
        guard let best else {
            if controller != nil { detachController(clearFeedback: false) }
            return
        }
        if best === controller { return }
        detachController(clearFeedback: true)
        attach(best)
    }

    private func controllerDisconnected(_ gone: GCController?) {
        if gone == nil || gone === controller {
            detachController(clearFeedback: false)
            send(currentSnapshot(), force: true) // neutral: buttons released
            selectController()
        }
    }

    private func attach(_ c: GCController) {
        controller = c
        c.handlerQueue = queue
        c.playerIndex = .index1
        keyboard = KeyboardState() // keys held when the pad appeared would never see their key-up
        if let pad = c.extendedGamepad {
            // PS / Create / Share must reach the PS5 instead of triggering macOS gestures
            // (Launchpad / screenshot / game overlay).
            for button in [pad.buttonHome, pad.buttonOptions, pad.buttonMenu] {
                button?.preferredSystemGestureState = .disabled
            }
            if let xbox = pad as? GCXboxGamepad { xbox.buttonShare?.preferredSystemGestureState = .disabled }
            pad.valueChangedHandler = { [weak self] _, _ in self?.sendIfChanged() }
        }
        if let motion = c.motion, motion.sensorsRequireManualActivation {
            motion.sensorsActive = true
        }
        hidTriggersFailed = false
        let isDualSense = c.extendedGamepad is GCDualSenseGamepad
        attachedFeedbackMode = DualSenseFeedbackMode.stored()
        if isDualSense, attachedFeedbackMode == .exact {
            openDualSense()
        } else {
            useCompatibleFeedback(reason: isDualSense ? "setting" : nil)
        }
        applyLastTriggers(force: true) // controller reconnected mid-session
        touchSlots = [TouchSlot(), TouchSlot()]
        triggerFilter.reset()
        rumble = (0, 0)
        hapticLevel = (0, 0)
        let name = c.vendorName ?? c.productCategory
        DispatchQueue.main.async {
            self.controllerConnectedMain = true
            self.controllerName = name
        }
        sendIfChanged()
    }

    private func detachController(clearFeedback: Bool, closeWait: TimeInterval = 0) {
        guard let c = controller else { return }
        if clearFeedback, dualSense == nil || hidTriggersFailed, let ds = c.extendedGamepad as? GCDualSenseGamepad {
            ds.leftTrigger.setModeOff()
            ds.rightTrigger.setModeOff()
        }
        dualSense?.close(clearFeedback: clearFeedback, wait: closeWait)
        dualSense = nil
        setSummary("none")
        c.extendedGamepad?.valueChangedHandler = nil
        if let motion = c.motion, motion.sensorsRequireManualActivation { motion.sensorsActive = false }
        haptics?.set(left: 0, right: 0)
        haptics?.shutdown()
        haptics = nil
        controller = nil
        touchSlots = [TouchSlot(), TouchSlot()]
        triggerFilter.reset()
        DispatchQueue.main.async {
            self.controllerConnectedMain = false
            self.controllerName = nil
        }
    }

    // MARK: Snapshot building

    private static func axis(_ v: Float) -> Int16 {
        let c = min(max(v, -1), 1)
        return c >= 0 ? Int16(c * 32767) : Int16(c * 32768)
    }

    private static func trigger(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255) }

    private func currentSnapshot() -> ControllerSnapshot {
        var s = ControllerSnapshot()
        if let pad = controller?.extendedGamepad {
            read(pad, into: &s)
        } else {
            readKeyboard(into: &s)
        }
        return s
    }

    private func read(_ pad: GCExtendedGamepad, into s: inout ControllerSnapshot) {
        var b: ControllerSnapshot.Buttons = []
        func set(_ flag: ControllerSnapshot.Buttons, _ on: Bool?) { if on == true { b.insert(flag) } }
        set(.cross, pad.buttonA.isPressed)
        set(.circle, pad.buttonB.isPressed)
        set(.square, pad.buttonX.isPressed)
        set(.triangle, pad.buttonY.isPressed)
        set(.l1, pad.leftShoulder.isPressed)
        set(.r1, pad.rightShoulder.isPressed)
        set(.l3, pad.leftThumbstickButton?.isPressed)
        set(.r3, pad.rightThumbstickButton?.isPressed)
        set(.up, pad.dpad.up.isPressed)
        set(.down, pad.dpad.down.isPressed)
        set(.left, pad.dpad.left.isPressed)
        set(.right, pad.dpad.right.isPressed)
        set(.options, pad.buttonMenu.isPressed)
        set(.share, pad.buttonOptions?.isPressed)
        set(.ps, pad.buttonHome?.isPressed)

        // GameController's +y is up; the PS5's is down.
        s.leftX = Self.axis(pad.leftThumbstick.xAxis.value)
        s.leftY = Self.axis(-pad.leftThumbstick.yAxis.value)
        s.rightX = Self.axis(pad.rightThumbstick.xAxis.value)
        s.rightY = Self.axis(-pad.rightThumbstick.yAxis.value)
        // Jitter must not push a trigger release out of chiaki's history window (TriggerFilter.swift).
        let triggers = triggerFilter.apply(l2: Self.trigger(pad.leftTrigger.value),
                                           r2: Self.trigger(pad.rightTrigger.value),
                                           now: HostClock.seconds(HostClock.now()))
        s.l2 = triggers.l2
        s.r2 = triggers.r2

        var touchpads: (GCControllerDirectionPad, GCControllerDirectionPad)?
        if let ds = pad as? GCDualSenseGamepad {
            set(.touchpad, ds.touchpadButton.isPressed)
            touchpads = (ds.touchpadPrimary, ds.touchpadSecondary)
        } else if let ds4 = pad as? GCDualShockGamepad {
            set(.touchpad, ds4.touchpadButton.isPressed)
            touchpads = (ds4.touchpadPrimary, ds4.touchpadSecondary)
        } else if let xbox = pad as? GCXboxGamepad {
            set(.touchpad, xbox.buttonShare?.isPressed)
        }
        s.buttons = b
        if let (primary, secondary) = touchpads {
            let touches = [touch(slot: 0, primary), touch(slot: 1, secondary)]
            // Click only (default): some games act on a touch alone (chiaki-ng #894).
            s.touches = TouchpadMode.stored() == .clickOnly ? [ControllerSnapshot.Touch(), ControllerSnapshot.Touch()] : touches
        }
    }

    private func touch(slot: Int, _ surface: GCControllerDirectionPad) -> ControllerSnapshot.Touch {
        let x = surface.xAxis.value, y = surface.yAxis.value
        // GameController resets a lifted finger to exactly (0, 0); a real finger is almost never there.
        let down = !(x == 0 && y == 0)
        if down && !touchSlots[slot].down {
            touchSlots[slot].id = nextTouchID
            nextTouchID = (nextTouchID &+ 1) & 0x7F
        }
        touchSlots[slot].down = down
        guard down else { return ControllerSnapshot.Touch() }
        let px = (min(max(x, -1), 1) + 1) / 2 * 1919
        let py = (1 - min(max(y, -1), 1)) / 2 * 1079
        return ControllerSnapshot.Touch(id: touchSlots[slot].id, x: UInt16(px.rounded()), y: UInt16(py.rounded()))
    }

    /// GameController → SDL sensor convention (X right, Y up, Z towards the player; gyro rad/s
    /// right-handed about those axes; accel in g, +1 on Y when the pad lies flat).
    /// GCMotion reports acceleration in the CoreMotion sense (gravity points *down*, i.e. a pad at rest
    /// reads ≈ (0, -1, 0)), whereas SDL/the PS5 expect the accelerometer reaction (≈ (0, +1, 0)), hence
    /// the negation.
    static func sdlMotion(_ m: GCMotion) -> (gyro: SIMD3<Float>, accel: SIMD3<Float>) {
        let a: GCAcceleration
        if m.hasGravityAndUserAcceleration {
            a = GCAcceleration(x: m.gravity.x + m.userAcceleration.x,
                               y: m.gravity.y + m.userAcceleration.y,
                               z: m.gravity.z + m.userAcceleration.z)
        } else {
            a = m.acceleration
        }
        let accel = SIMD3<Float>(Float(-a.x), Float(-a.y), Float(-a.z))
        let r = m.rotationRate
        let gyro = m.hasRotationRate ? SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z)) : .zero
        return (gyro, accel)
    }

    private func addMotion(into s: inout ControllerSnapshot) {
        guard let m = controller?.motion else { return }
        let (gyro, accel) = Self.sdlMotion(m)
        s.gyro = gyro
        s.accel = accel
        s.motionValid = true
        s.motionTimestampUs = UInt64(HostClock.seconds(HostClock.now()) * 1_000_000)
    }

    // MARK: Sending

    private func sendIfChanged() {
        guard running else { return }
        var s = currentSnapshot()
        // Motion is refreshed on ticks; reuse the last values so a button change carries valid motion.
        if let last = lastSent {
            s.motionValid = last.motionValid
            s.gyro = last.gyro
            s.accel = last.accel
            s.motionTimestampUs = last.motionTimestampUs
        }
        send(s, force: false)
    }

    private func send(_ s: ControllerSnapshot, force: Bool) {
        if !force, let last = lastSent, last == s { return }
        lastSent = s
        sink?.send(s)
    }

    private func tick() {
        guard running else { return }
        var s = currentSnapshot()
        addMotion(into: &s)
        // Keepalive: always send on the tick, even when nothing changed.
        send(s, force: true)
        updateHaptics()
    }

    // MARK: Feedback

    func apply(_ feedback: ControllerFeedbackEvent) {
        queue.async { [self] in
            switch feedback {
            case let .rumble(l, r):
                rumble = (Float(l) / 255, Float(r) / 255)
                updateHaptics()
            case let .haptics(samples):
                if let dualSense, dualSense.consumesPCM {
                    dualSense.haptics(samples)
                    if samples.contains(where: { $0 != 0 }) { lastHapticsHostTime = HostClock.now() }
                    updateHaptics()
                    return
                }
                // Stereo S16 @ 3 kHz: RMS per channel → intensity (×2 so typical content reaches ~1).
                let frames = samples.count / 2
                guard frames > 0 else { return }
                var sumL = 0.0, sumR = 0.0
                for i in 0..<frames {
                    let l = Double(samples[2 * i]) / 32768, r = Double(samples[2 * i + 1]) / 32768
                    sumL += l * l
                    sumR += r * r
                }
                hapticLevel = (Float(min(1, 2 * (sumL / Double(frames)).squareRoot())),
                               Float(min(1, 2 * (sumR / Double(frames)).squareRoot())))
                lastHapticsHostTime = HostClock.now()
                updateHaptics()
            case let .triggers(typeLeft, left, typeRight, right):
                lastTriggers = (typeLeft, left, typeRight, right)
                applyLastTriggers()
            case .motionReset:
                break
            }
        }
    }

    /// A stream ended (the manager itself keeps running): forget the console's feedback and leave
    /// the pad neutral, so the last effect neither stays on the triggers nor comes back on the next
    /// app activation. Returns the HID write stats for the stream trace (nil without HID). Main thread.
    @discardableResult
    func resetFeedback() -> String? {
        queue.sync { [self] in
            lastTriggers = nil
            rumble = (0, 0)
            hapticLevel = (0, 0)
            updateHaptics()
            if dualSense == nil || hidTriggersFailed, let ds = controller?.extendedGamepad as? GCDualSenseGamepad {
                ds.leftTrigger.setModeOff()
                ds.rightTrigger.setModeOff()
            }
            return dualSense?.endStream()
        }
    }

    /// Handler queue only. `force` re-sends an unchanged HID effect (activation, reconnect).
    private func applyLastTriggers(force: Bool = false) {
        guard let t = lastTriggers, let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        if let dualSense, !hidTriggersFailed {
            dualSense.setTriggers(typeLeft: t.typeLeft, left: t.left, typeRight: t.typeRight, right: t.right, force: force)
            return
        }
        TriggerEffectMapper.apply(type: t.typeLeft, params: t.left, to: ds.leftTrigger)
        TriggerEffectMapper.apply(type: t.typeRight, params: t.right, to: ds.rightTrigger)
    }

    private func updateHaptics() {
        if hapticLevel != (0, 0),
           HostClock.seconds(HostClock.now() &- lastHapticsHostTime) > Self.hapticsHoldSeconds {
            hapticLevel = (0, 0)
        }
        guard let dualSense else {
            haptics?.set(left: max(rumble.l, hapticLevel.l), right: max(rumble.r, hapticLevel.r))
            return
        }
        if dualSense.consumesPCM {
            // PCM goes to the pad as-is; report rumble would take the actuators out of audio mode.
            let streaming = HostClock.seconds(HostClock.now() &- lastHapticsHostTime) < Self.pcmActiveSeconds
            dualSense.setRumble(left: streaming ? 0 : rumble.l, right: streaming ? 0 : rumble.r)
        } else {
            dualSense.setRumble(left: max(rumble.l, hapticLevel.l), right: max(rumble.r, hapticLevel.r))
        }
    }

    // MARK: DualSense Exact / Compatible

    /// How feedback reaches the controller, for the session trace. Any thread.
    var feedbackSummary: String {
        summaryLock.lock(); defer { summaryLock.unlock() }
        return _feedbackSummary
    }

    private func setSummary(_ text: String) {
        summaryLock.lock(); _feedbackSummary = text; summaryLock.unlock()
    }

    /// Handler queue only. Applies a changed Exact/Compatible setting to the connected DualSense.
    private func feedbackSettingMaybeChanged() {
        guard running, let c = controller, c.extendedGamepad is GCDualSenseGamepad,
              DualSenseFeedbackMode.stored() != attachedFeedbackMode else { return }
        detachController(clearFeedback: true)
        attach(c)
    }

    /// Handler queue only. Falls back to Compatible when the HID device can't be opened.
    private func openDualSense() {
        guard let output = DualSenseOutput.open(log: { Diagnostics.shared.event($0) }) else {
            useCompatibleFeedback(reason: "HID unavailable")
            return
        }
        output.onTriggerFailure = { [weak self, weak output] in
            self?.queue.async {
                guard let self, let output, self.dualSense === output else { return }
                Diagnostics.shared.event("dualsense: HID trigger write failed, triggers via GameController")
                self.hidTriggersFailed = true
                self.setSummary(output.summary + ", triggers: GameController")
                self.applyLastTriggers(force: true)
            }
        }
        output.onDeviceFailure = { [weak self, weak output] in
            self?.queue.async {
                guard let self, let output, self.dualSense === output else { return }
                output.close(clearFeedback: false, wait: 0)
                self.dualSense = nil
                self.useCompatibleFeedback(reason: "HID writes failing")
                self.applyLastTriggers(force: true)
            }
        }
        output.clearTriggers() // whatever GameController or an earlier app left on the pad
        dualSense = output
        haptics = nil
        setSummary(output.summary)
        Diagnostics.shared.event("dualsense feedback: \(output.summary)")
    }

    /// Handler queue only. GameController triggers + CoreHaptics; `reason` is nil for other pads.
    private func useCompatibleFeedback(reason: String?) {
        guard let c = controller else { return }
        if let ds = c.extendedGamepad as? GCDualSenseGamepad {
            ds.leftTrigger.setModeOff()
            ds.rightTrigger.setModeOff()
        }
        haptics = ControllerHaptics(controller: c)
        let text = reason.map { "compatible GameController (\($0))" } ?? "GameController"
        setSummary(text)
        if reason != nil { Diagnostics.shared.event("dualsense feedback: \(text)") }
    }

    // MARK: Keyboard / mouse fallback

    /// Main thread (stream view). Returns true when the event was consumed by the fallback mapping.
    func handle(event: NSEvent) -> Bool {
        guard !controllerConnectedMain else { return false }
        switch event.type {
        case .keyDown, .keyUp:
            if event.modifierFlags.contains(.command) { return false }
            let code = event.keyCode
            guard Self.mappedKeys.contains(code) else { return false }
            let down = event.type == .keyDown
            if down && event.isARepeat { return true }
            queue.async { [self] in
                if down { keyboard.keys.insert(code) } else { keyboard.keys.remove(code) }
                sendIfChanged()
            }
            return true
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let type = event.type
            queue.async { [self] in
                switch type {
                case .leftMouseDown: keyboard.leftMouse = true
                case .leftMouseUp: keyboard.leftMouse = false
                case .rightMouseDown: keyboard.rightMouse = true
                default: keyboard.rightMouse = false
                }
                sendIfChanged()
            }
            return true
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let delta = SIMD2<Double>(Double(event.deltaX), Double(event.deltaY)) // deltaY: +down already
            queue.async { [self] in
                keyboard.mouseDelta = delta
                keyboard.mouseHostTime = HostClock.now()
                sendIfChanged()
            }
            return true
        default:
            return false
        }
    }

    private enum Key {
        static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, h: UInt16 = 4, g: UInt16 = 5
        static let z: UInt16 = 6, x: UInt16 = 7, v: UInt16 = 9, b: UInt16 = 11, q: UInt16 = 12
        static let w: UInt16 = 13, e: UInt16 = 14, r: UInt16 = 15, y: UInt16 = 16
        static let i: UInt16 = 34, p: UInt16 = 35, ret: UInt16 = 36, l: UInt16 = 37, j: UInt16 = 38, k: UInt16 = 40
        static let space: UInt16 = 49, delete: UInt16 = 51
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    private static let keyButtons: [UInt16: ControllerSnapshot.Buttons] = [
        Key.space: .cross, Key.q: .circle, Key.e: .square, Key.r: .triangle,
        Key.i: .up, Key.j: .left, Key.k: .down, Key.l: .right,
        Key.z: .l1, Key.x: .r1, Key.v: .l3, Key.b: .r3,
        Key.ret: .options, Key.delete: .share, Key.p: .ps, Key.y: .touchpad,
    ]

    private static let mappedKeys: Set<UInt16> = Set(keyButtons.keys).union([
        Key.w, Key.a, Key.s, Key.d, Key.g, Key.h, Key.left, Key.right, Key.up, Key.down,
    ])

    private func readKeyboard(into s: inout ControllerSnapshot) {
        let keys = keyboard.keys
        var b: ControllerSnapshot.Buttons = []
        for (code, flag) in Self.keyButtons where keys.contains(code) { b.insert(flag) }
        s.buttons = b

        func pair(_ neg: UInt16, _ pos: UInt16) -> Int16 {
            (keys.contains(pos) ? 32767 : 0) - (keys.contains(neg) ? 32767 : 0)
        }
        s.leftX = pair(Key.a, Key.d)
        s.leftY = pair(Key.w, Key.s)

        var rx = pair(Key.left, Key.right), ry = pair(Key.up, Key.down)
        if rx == 0 && ry == 0,
           HostClock.seconds(HostClock.now() &- keyboard.mouseHostTime) < Self.mouseHoldSeconds {
            func clampStick(_ v: Double) -> Int16 { Int16(min(max(v, -32768), 32767)) }
            rx = clampStick(keyboard.mouseDelta.x * Self.mouseGain)
            ry = clampStick(keyboard.mouseDelta.y * Self.mouseGain)
        }
        s.rightX = rx
        s.rightY = ry

        s.l2 = (keys.contains(Key.g) || keyboard.rightMouse) ? 255 : 0
        s.r2 = (keys.contains(Key.h) || keyboard.leftMouse) ? 255 : 0
    }
}

/// Whether finger positions on the DualSense touchpad are sent to the PS5 (the click always is).
enum TouchpadMode: String, CaseIterable, Identifiable {
    case clickOnly, touchAndClick
    var id: String { rawValue }
    static let defaultsKey = "framelift.touchpad.v1"
    var title: String { self == .clickOnly ? "Click only (recommended)" : "Touch + click" }
    static func stored(_ defaults: UserDefaults = .standard) -> TouchpadMode {
        defaults.string(forKey: defaultsKey).flatMap(TouchpadMode.init(rawValue:)) ?? .clickOnly
    }
}
