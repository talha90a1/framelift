// SPDX-License-Identifier: AGPL-3.0-only
// Exact DualSense feedback over raw HID: the PS5's trigger bytes and haptics PCM, unchanged.
// Bluetooth haptics stream as 0x32 reports; USB haptics go to audio channels 3/4 (DualSenseUSBHaptics.swift).
// Pump constants follow P5M (DualSenseHaptics.kt, AGPL-3.0, commit d61c8e6).
// Every method is called from InputManager's queue; callbacks arrive on the writer queue.
import Foundation
import IOKit

/// Controller feedback preference. Full effects fall back to Standard when HID is unavailable.
enum DualSenseFeedbackMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case exact
    case compatible

    static let defaultsKey = "framelift.dualsenseFeedback.v1"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic (recommended)"
        case .exact: "Full effects (USB recommended)"
        case .compatible: "Standard effects"
        }
    }

    func usesRawHID(over transport: DualSenseTransport) -> Bool {
        self == .exact || (self == .automatic && transport == .usb)
    }

    static func stored(_ defaults: UserDefaults = .standard) -> DualSenseFeedbackMode {
        defaults.string(forKey: defaultsKey).flatMap(DualSenseFeedbackMode.init(rawValue:)) ?? .automatic
    }
}

final class DualSenseOutput: @unchecked Sendable {
    enum HapticsRoute: String {
        case bluetoothStream = "0x32 stream"
        case usbAudio = "USB audio ch 3/4"
        case reportRumble = "report rumble envelope"
    }

    static let failuresBeforeGivingUp = 8

    let transport: DualSenseTransport
    let product: String
    private(set) var hapticsRoute: HapticsRoute
    /// True while the console's PCM goes to the pad as-is (no envelope needed).
    var consumesPCM: Bool {
        if usbAudio == nil, let audio = usbRecovery?.poll() {
            usbAudio = audio
            hapticsRoute = .usbAudio
            setRumble(left: 0, right: 0)
            log("dualsense USB audio became available; haptics switched to USB audio")
            onRouteChanged?()
        }
        return hapticsRoute != .reportRumble
    }

    /// InputManager queue, after a delayed USB audio device becomes usable.
    var onRouteChanged: (() -> Void)?

    /// Writer queue. A trigger write failed: use the GameController mapping for triggers.
    var onTriggerFailure: (() -> Void)?
    /// Writer queue. Writes keep failing (pad gone or refusing): fall back entirely.
    var onDeviceFailure: (() -> Void)?

    private let writer: DualSenseHIDWriter
    private let log: @Sendable (String) -> Void
    private var pump: BluetoothHapticsPump?
    private var usbAudio: (any USBHapticsDevice)?
    private var usbRecovery: USBHapticsRecovery?
    private var lastTriggerBlock: [UInt8]?
    private var lastRumble: (UInt8, UInt8) = (0, 0)
    private var lastIntensity: (ControllerEffectIntensity, ControllerEffectIntensity)?

    // Writer queue only.
    private var consecutiveFailures = 0
    private var reportedTriggerFailure = false
    private var reportedDeviceFailure = false
    /// First result per kind is logged (again after `endStream`, so every stream trace has one).
    private var loggedKinds = Set<DualSenseHIDWriter.Kind>()

    /// Opens the single connected DualSense. Nil (with the reason logged) when raw HID is unusable.
    static func open(mode: DualSenseFeedbackMode = .automatic, onTransport: ((DualSenseTransport) -> Void)? = nil, log: @escaping @Sendable (String) -> Void) -> DualSenseOutput? {
        switch DualSenseHIDDevice.openSingle() {
        case .success(let device):
            onTransport?(device.transport)
            guard mode.usesRawHID(over: device.transport) else {
                device.close()
                log("dualsense: standard feedback selected for \(device.transport.rawValue)")
                return nil
            }
            return DualSenseOutput(device: device, log: log)
        case .failure(let error): log("dualsense hid unavailable: \(error)"); return nil
        }
    }

    private init(device: DualSenseHIDDevice, log: @escaping @Sendable (String) -> Void) {
        transport = device.transport
        product = device.product
        self.log = log
        writer = DualSenseHIDWriter(device: device)
        hapticsRoute = .reportRumble
        writer.onResult = { [weak self] kind, result in self?.handle(kind, result) }

        if transport == .bluetooth {
            writer.perform { [log] in
                let r = device.readCalibration()
                log(String(format: "dualsense feature 0x05 read: 0x%08x", r))
            }
        }
        // Full actuator power and the low-pass filter before any haptics (both transports).
        writer.submit(.setup, DualSenseReports.stateReport(DualSenseReports.powerSetupBlock(), transport: transport))

        switch transport {
        case .bluetooth:
            pump = BluetoothHapticsPump(writer: writer)
            hapticsRoute = .bluetoothStream
        case .usb:
            usbRecovery = USBHapticsRecovery { [log] in DualSenseUSBHaptics(log: log) }
        }
    }

    var summary: String { "exact HID over \(transport.rawValue) (\(product)), haptics: \(hapticsRoute.rawValue)" }

    // MARK: Feedback

    func setIntensity(haptic: ControllerEffectIntensity, trigger: ControllerEffectIntensity) {
        if let lastIntensity, lastIntensity == (haptic, trigger) { return }
        lastIntensity = (haptic, trigger)
        writer.submit(.setup, DualSenseReports.stateReport(
            DualSenseReports.powerSetupBlock(haptic: haptic, trigger: trigger), transport: transport))
    }

    /// Sent on change only: re-sending restarts the effect.
    func setTriggers(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8], force: Bool = false) {
        let block = DualSenseReports.triggerBlock(typeLeft: typeLeft, left: left, typeRight: typeRight, right: right)
        if !force, block == lastTriggerBlock { return }
        lastTriggerBlock = block
        writer.submit(.triggers, DualSenseReports.stateReport(block, transport: transport))
    }

    func clearTriggers() {
        let off = DualSenseReports.triggerOff
        setTriggers(typeLeft: off.type, left: off.params, typeRight: off.type, right: off.params, force: true)
    }

    /// 0...1 per side (motor emulation). Sent on change.
    func setRumble(left: Float, right: Float) {
        let v = (UInt8(min(max(left, 0), 1) * 255), UInt8(min(max(right, 0), 1) * 255))
        if v == lastRumble { return }
        lastRumble = v
        writer.submit(.rumble, DualSenseReports.stateReport(DualSenseReports.rumbleBlock(left: v.0, right: v.1), transport: transport))
    }

    /// Stereo S16 @ 3 kHz from the console.
    func haptics(_ samples: [Int16]) {
        pump?.enqueue(samples)
        usbAudio?.enqueue(samples)
    }

    /// A stream ended: neutral triggers and motors, and the write stats since the last call.
    func endStream() -> String {
        clearTriggers()
        setRumble(left: 0, right: 0)
        writer.perform { [self] in loggedKinds.removeAll() }
        return writer.takeStats().text
    }

    /// Neutral triggers and motors (if `clearFeedback`), then close. `wait` bounds how long the
    /// caller blocks for those last writes.
    func close(clearFeedback: Bool, wait: TimeInterval) {
        pump?.stop()
        pump = nil
        usbRecovery?.stop()
        usbRecovery = nil
        usbAudio?.stop()
        usbAudio = nil
        if clearFeedback {
            clearTriggers()
            setRumble(left: 0, right: 0)
        }
        writer.close(wait: wait)
    }

    // MARK: Results (writer queue)

    private func handle(_ kind: DualSenseHIDWriter.Kind, _ result: IOReturn) {
        if !loggedKinds.contains(kind) || (result != kIOReturnSuccess && consecutiveFailures == 0) {
            loggedKinds.insert(kind)
            log(String(format: "dualsense hid %@ write: 0x%08x", kind.rawValue, result))
        }
        guard result != kIOReturnSuccess else { consecutiveFailures = 0; return }
        consecutiveFailures += 1
        if kind == .triggers, !reportedTriggerFailure {
            reportedTriggerFailure = true
            onTriggerFailure?()
        }
        if consecutiveFailures >= Self.failuresBeforeGivingUp, !reportedDeviceFailure {
            reportedDeviceFailure = true
            log("dualsense hid: \(consecutiveFailures) writes failed in a row, falling back to GameController")
            onDeviceFailure?()
        }
    }
}

/// Paces the Bluetooth 0x32 stream from a small ring of signed 8-bit stereo samples.
final class BluetoothHapticsPump: @unchecked Sendable {
    /// 32 frames, 0.05% slower than 3 kHz so the pad's queue never grows.
    static let periodNanos = 10_672_000
    static let ringCap = 320
    static let flushAfterEmptyTicks = 2
    static let parkAfterIdleTicks = 24

    private let writer: DualSenseHIDWriter
    private let queue = DispatchQueue(label: "framelift.dualsense.haptics", qos: .userInteractive)
    private let lock = NSLock()
    private var ring: [Int8] = []        // lock
    private var timer: DispatchSourceTimer? // queue
    private var flowing = false            // queue
    private var emptyTicks = 0             // queue
    private var idleTicks = 0              // queue
    private var stopped = false            // lock

    init(writer: DualSenseHIDWriter) { self.writer = writer }

    func enqueue(_ samples: [Int16]) {
        var converted = [Int8](repeating: 0, count: samples.count & ~1)
        var any = false
        for i in 0..<converted.count {
            converted[i] = DualSenseReports.toSigned8(samples[i])
            any = any || converted[i] != 0
        }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let parkedAndSilent = !any && ring.isEmpty
        if !parkedAndSilent {
            ring.append(contentsOf: converted)
            if ring.count > Self.ringCap { ring.removeFirst((ring.count - Self.ringCap + 1) & ~1) }
        }
        lock.unlock()
        if any { queue.async { [self] in startTimer() } }
    }

    func stop() {
        lock.lock()
        stopped = true
        ring.removeAll()
        lock.unlock()
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    private func startTimer() {
        guard timer == nil else { return }
        idleTicks = 0
        emptyTicks = 0
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Self.periodNanos), leeway: .microseconds(300))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let block = DualSenseReports.hapticsBytes
        lock.lock()
        var take: [Int8]?
        if ring.count >= block {
            flowing = true
            take = Array(ring.prefix(block))
            ring.removeFirst(block)
            emptyTicks = 0
        } else if !ring.isEmpty {
            emptyTicks += 1
            if emptyTicks >= Self.flushAfterEmptyTicks { // end of a burst: send the tail padded
                take = ring
                ring.removeAll()
                flowing = false
                emptyTicks = 0
            }
        } else {
            flowing = false
        }
        lock.unlock()

        if let take, take.contains(where: { $0 != 0 }) {
            idleTicks = 0
            writer.submit(.haptics, DualSenseReports.hapticsReport(take))
        } else {
            idleTicks += 1
            if idleTicks >= Self.parkAfterIdleTicks { timer?.cancel(); timer = nil; flowing = false }
        }
    }
}
