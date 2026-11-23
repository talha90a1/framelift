// SPDX-License-Identifier: AGPL-3.0-only
// Input-to-display latency probe (Cmd+Shift+L): times a button press to the first frame whose luma changes.
// Sits between input -> session and decoder -> renderer; only in the pipeline with "Debug logs" on.
import CoreVideo
import Foundation

final class LatencyProbe: ControllerSink, FrameSink, @unchecked Sendable {
    private let controller: ControllerSink
    private let frames: FrameSink
    private let status: ProbeStatus
    private let lock = NSLock()
    private var active = false
    private var lastButtons: ControllerSnapshot.Buttons = []
    private var pressTime: UInt64?
    private var previous: [UInt8]?
    private var baseline: Double = 4 // EMA of ordinary frame-to-frame luma change (0-255)
    private var samples: [Double] = []
    // Automatic mode.
    private var autoPrevious: [UInt8]?
    private var stillFrames = 0
    private var autoPress: UInt64?
    private var autoSamples: [Double] = []
    private static let autoButtons: ControllerSnapshot.Buttons = [.cross, .circle, .square, .triangle, .left, .right, .up, .down, .l1, .r1, .options]

    /// Shown by the telemetry overlay while active (main thread reads under its lock).
    static let status = ProbeStatus()

    init(controller: ControllerSink, frames: FrameSink, status: ProbeStatus = LatencyProbe.status) {
        self.controller = controller
        self.frames = frames
        self.status = status
    }

    var isActive: Bool { lock.withLock { active } }

    /// Arms the probe, or stops it when it is already armed. Returns whether it runs now.
    @discardableResult
    func toggle() -> Bool {
        if isActive {
            stop()
            return false
        }
        lock.withLock {
            active = true
            pressTime = nil; previous = nil; samples = []
        }
        status.set("armed: press Options (pause menu) ~10×")
        Diagnostics.shared.event("latency probe armed (Options)")
        return true
    }

    /// Safe to call when idle.
    func stop() {
        let wasActive = lock.withLock { () -> Bool in
            defer { active = false; pressTime = nil; previous = nil; samples = [] }
            return active
        }
        guard wasActive else { return }
        status.set(nil)
        Diagnostics.shared.event("latency probe off")
    }

    // MARK: ControllerSink

    func send(_ state: ControllerSnapshot) {
        lock.withLock {
            if active, state.buttons.contains(.options), !lastButtons.contains(.options), pressTime == nil {
                pressTime = HostClock.now()
            }
            let pressed = state.buttons.subtracting(lastButtons)
            if !active, autoPress == nil, stillFrames >= 6, !pressed.intersection(Self.autoButtons).isEmpty {
                autoPress = HostClock.now()
            }
            lastButtons = state.buttons
        }
        controller.send(state)
    }

    // MARK: FrameSink

    func submit(_ frame: DecodedFrame) {
        if let thumb = Self.thumbnail(frame.pixelBuffer) {
            if isActive { observeManual(thumb, arrival: frame.arrivalHostTime) } else { observeAuto(thumb, arrival: frame.arrivalHostTime) }
        }
        frames.submit(frame)
    }

    func reset() {
        lock.withLock { previous = nil; autoPrevious = nil; stillFrames = 0; autoPress = nil }
        frames.reset()
    }

    // MARK: Frames

    private func observeManual(_ thumb: [UInt8], arrival: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        defer { previous = thumb }
        guard let prev = previous, prev.count == thumb.count else { return }
        var sum = 0
        for i in 0..<thumb.count { sum += abs(Int(thumb[i]) - Int(prev[i])) }
        let diff = Double(sum) / Double(thumb.count)

        if let press = pressTime {
            let waited = HostClock.milliseconds(from: press, to: arrival)
            if waited > 0, diff > max(18, baseline * 4) {
                samples.append(waited)
                pressTime = nil
                let sorted = samples.sorted()
                let median = sorted[sorted.count / 2]
                let a2p = RenderTelemetry.shared.snapshot.realArrivalToPhotonMsP50
                let text = String(format: "round trip %.0f ms (median %.0f of %d) + screen %.0f ≈ %.0f ms",
                                  waited, median, samples.count, a2p, median + a2p)
                status.set(text)
                Diagnostics.shared.event(String(format: "latency probe sample %.1f ms (diff %.1f, baseline %.1f) median %.1f n=%d a2p %.1f",
                                                waited, diff, baseline, median, samples.count, a2p))
                return
            }
            if waited > 1500 {
                pressTime = nil
                status.set("no picture change within 1.5 s; press Options again")
                Diagnostics.shared.event(String(format: "latency probe timeout (diff %.1f)", diff))
            }
        }
        baseline += (min(diff, 40) - baseline) * 0.05
    }

    /// Times a press made on a still screen to the first frame where a visible part of it changes.
    private func observeAuto(_ thumb: [UInt8], arrival: UInt64) {
        lock.lock(); defer { lock.unlock() }
        defer { autoPrevious = thumb }
        guard let prev = autoPrevious, prev.count == thumb.count else { return }
        // Samples that changed by more than 24 of 255: encoder noise on a still screen stays below it.
        var changed = 0
        for i in 0..<thumb.count where abs(Int(thumb[i]) - Int(prev[i])) > 24 { changed += 1 }
        if let press = autoPress {
            let waited = HostClock.milliseconds(from: press, to: arrival)
            if waited > 0, changed >= 6 {
                autoPress = nil
                stillFrames = 0
                autoSamples.append(waited)
                if autoSamples.count > 50 { autoSamples.removeFirst() }
                let sorted = autoSamples.sorted()
                let median = sorted[sorted.count / 2]
                let glass = RenderTelemetry.shared.snapshot.realArrivalToPhotonMsP50
                Diagnostics.shared.event(String(format: "input lag: press->frame %.1f ms + arrival->glass %.1f = %.1f ms | median %.1f + %.1f = %.1f ms (n=%d)",
                                                waited, glass, waited + glass, median, glass, median + glass, autoSamples.count))
                return
            }
            if waited > 600 { autoPress = nil }
        }
        stillFrames = changed <= 1 ? stillFrames + 1 : 0
    }

    /// 64×36 samples of the luma plane.
    private static func thumbnail(_ buffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let tenBit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let p = base.assumingMemoryBound(to: UInt8.self)
        let gw = 64, gh = 36
        var out = [UInt8](); out.reserveCapacity(gw * gh)
        for gy in 0..<gh {
            let y = (gy * 2 + 1) * h / (gh * 2)
            for gx in 0..<gw {
                let x = (gx * 2 + 1) * w / (gw * 2)
                if tenBit {
                    let v = p.advanced(by: y * stride + x * 2).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
                    out.append(UInt8(truncatingIfNeeded: v >> 8))
                } else {
                    out.append(p[y * stride + x])
                }
            }
        }
        return out
    }
}

final class ProbeStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ text: String?) { lock.lock(); value = text; lock.unlock() }
    var text: String? { lock.lock(); defer { lock.unlock() }; return value }
}
