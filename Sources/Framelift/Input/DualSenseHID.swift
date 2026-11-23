// SPDX-License-Identifier: AGPL-3.0-only
// Raw IOKit HID access to a DualSense, next to GameController (never seized).
// Matching, non-exclusive open and transport detection follow cestercian/ps5-mac-companion (MIT,
// Copyright (c) 2026 Cestercian); the Bluetooth 0x05 activation read follows brc-xyz/dsfm (MIT,
// Copyright (c) 2026 Alexandru Bracau); report sequencing as in P5M (AGPL-3.0).
// Writes use the synchronous IOHIDDeviceSetReport, `maxInFlight` at a time (the callback variant
// drops more haptics blocks). State reports go out only on an idle pipe, coalesced per kind.
import Foundation
import IOKit
import IOKit.hid

final class DualSenseHIDDevice: @unchecked Sendable {
    static let vendorID = 0x054C
    static let productIDs = [0x0CE6, 0x0DF2]

    enum OpenError: Error, CustomStringConvertible {
        case noDevice, ambiguous(Int), deviceOpen(IOReturn)
        var description: String {
            switch self {
            case .noDevice: "no DualSense HID device"
            case .ambiguous(let n): "\(n) DualSense HID devices, cannot tell which one GameController uses"
            case .deviceOpen(let r): String(format: "IOHIDDeviceOpen failed 0x%08x", r)
            }
        }
    }

    let transport: DualSenseTransport
    let product: String
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let lock = NSLock()
    private var closed = false

    private init(manager: IOHIDManager, device: IOHIDDevice) {
        self.manager = manager
        self.device = device
        let t = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        transport = t.lowercased().contains("bluetooth") ? .bluetooth : .usb
        product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "DualSense"
    }

    /// Finds the single connected DualSense and opens it without seizing it. More than one pad is
    /// refused: GameController does not expose which HID device backs a GCController.
    static func openSingle() -> Result<DualSenseHIDDevice, OpenError> {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = productIDs.map {
            [kIOHIDVendorIDKey: NSNumber(value: vendorID), kIOHIDProductIDKey: NSNumber(value: $0)] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        // Its result is not decisive (it reports the worst of all matched devices); IOHIDDeviceOpen
        // below is. Enumeration works without scheduling the manager on a run loop.
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        func fail(_ error: OpenError) -> Result<DualSenseHIDDevice, OpenError> {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return .failure(error)
        }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard let device = devices.first else { return fail(.noDevice) }
        guard devices.count == 1 else { return fail(.ambiguous(devices.count)) }
        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard open == kIOReturnSuccess else { return fail(.deviceOpen(open)) }
        return .success(DualSenseHIDDevice(manager: manager, device: device))
    }

    /// Synchronous output report write; `report[0]` is the report ID. Any thread.
    func write(_ report: [UInt8]) -> IOReturn {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed, let id = report.first else { return kIOReturnNotOpen }
        return report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), $0.baseAddress!, $0.count)
        }
    }

    /// GET feature report 0x05 (calibration, 41 bytes). On Bluetooth this switches the pad from the
    /// simple report to the full one that accepts 0x31/0x32 (dsfm).
    func readCalibration() -> IOReturn {
        var buf = [UInt8](repeating: 0, count: 41)
        buf[0] = 0x05
        var length = CFIndex(buf.count)
        return buf.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x05, $0.baseAddress!, &length)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

/// Ordered, non-blocking writer for one opened pad.
final class DualSenseHIDWriter: @unchecked Sendable {
    enum Kind: String { case setup, triggers, rumble, haptics }

    static let maxPendingHaptics = 4

    struct Stats {
        var writes = 0, failures = 0, droppedHaptics = 0
        var totalNanos: UInt64 = 0, maxNanos: UInt64 = 0

        var text: String {
            let avg = writes > 0 ? Double(totalNanos) / Double(writes) / 1e6 : 0
            return String(format: "%d writes, %d failed, %d haptics blocks dropped, write avg %.2f ms max %.2f ms",
                          writes, failures, droppedHaptics, avg, Double(maxNanos) / 1e6)
        }
    }

    let device: DualSenseHIDDevice
    let maxInFlight: Int
    /// Called on the writer queue after every write.
    var onResult: ((Kind, IOReturn) -> Void)?

    private let queue = DispatchQueue(label: "framelift.dualsense.hid", qos: .userInteractive)
    private let writers = DispatchQueue(label: "framelift.dualsense.hid.write", qos: .userInteractive, attributes: .concurrent)
    private let lock = NSLock()
    // lock:
    private var pending: [(kind: Kind, report: [UInt8])] = []
    private var draining = false
    private var closing = false
    private var inFlight = 0
    private var stats = Stats()
    private var closed: DispatchSemaphore?
    // queue:
    private var sequence = DualSenseReports.Sequence()

    init(device: DualSenseHIDDevice, maxInFlight: Int = 4) {
        self.device = device
        self.maxInFlight = max(1, maxInFlight)
    }

    /// Any thread. Returns immediately.
    func submit(_ kind: Kind, _ report: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closing else { return }
        if kind == .haptics {
            let waiting = pending.indices.filter { pending[$0].kind == .haptics }
            if waiting.count >= Self.maxPendingHaptics, let oldest = waiting.first {
                pending.remove(at: oldest)
                stats.droppedHaptics += 1
            }
            pending.append((kind, report))
        } else if let i = pending.firstIndex(where: { $0.kind == kind }) {
            pending[i].report = report // full state: only the latest matters
        } else {
            pending.append((kind, report))
        }
        kickLocked()
    }

    /// Runs `work` on the writer queue, before any write submitted after this call is issued.
    func perform(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    /// Write timing and drops since the last call. Any thread.
    func takeStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        let s = stats
        stats = Stats()
        return s
    }

    /// The next report may go out now: room in flight, and a state report waits for an idle pipe.
    private func canIssueLocked() -> Bool {
        guard let next = pending.first, inFlight < maxInFlight else { return false }
        return next.kind == .haptics || inFlight == 0
    }

    private func kickLocked() {
        guard !draining, canIssueLocked() else { return }
        draining = true
        queue.async { [self] in drain() }
    }

    /// Writer queue. Stamps and issues reports in order while they may go out.
    private func drain() {
        while true {
            lock.lock()
            guard canIssueLocked() else {
                draining = false
                finishCloseIfIdleLocked()
                lock.unlock()
                return
            }
            let (kind, unstamped) = pending.removeFirst()
            inFlight += 1
            lock.unlock()

            var stamped = unstamped
            sequence.stamp(&stamped)
            let report = stamped
            let start = DispatchTime.now().uptimeNanoseconds
            if maxInFlight == 1 {
                completed(kind, device.write(report), start)
            } else {
                writers.async { [self] in completed(kind, device.write(report), start) }
            }
        }
    }

    private func completed(_ kind: Kind, _ r: IOReturn, _ start: UInt64) {
        let took = DispatchTime.now().uptimeNanoseconds - start
        lock.lock()
        inFlight -= 1
        stats.writes += 1
        if r != kIOReturnSuccess { stats.failures += 1 }
        stats.totalNanos += took
        stats.maxNanos = max(stats.maxNanos, took)
        kickLocked()
        finishCloseIfIdleLocked()
        lock.unlock()
        queue.async { [self] in onResult?(kind, r) }
    }

    private func finishCloseIfIdleLocked() {
        guard closing, pending.isEmpty, inFlight == 0, let done = closed else { return }
        closed = nil
        queue.async { [self] in
            device.close()
            onResult = nil
            done.signal()
        }
    }

    /// Writes what is already queued (e.g. neutral triggers), then closes the device. Waits at most
    /// `wait` seconds for that (0 = fully asynchronous).
    func close(wait: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        closing = true
        closed = done
        kickLocked()
        finishCloseIfIdleLocked()
        lock.unlock()
        if wait > 0 { _ = done.wait(timeout: .now() + wait) }
    }
}
