// SPDX-License-Identifier: AGPL-3.0-only
// Render-module telemetry beyond the frozen Telemetry snapshot (real-frame arrival to glass, read by LatencyProbe).
import CoreVideo
import Foundation

final class RenderTelemetry: @unchecked Sendable {
    struct Snapshot: Sendable {
        /// presentedTime - arrivalHostTime of real frames, ms.
        var realArrivalToPhotonMsP50: Double = 0
    }

    static let shared = RenderTelemetry()
    private let lock = NSLock()
    private var value = Snapshot()

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLock { body(&value) }
    }

    var snapshot: Snapshot { lock.withLock { value } }
}

/// A 30 fps picture sent twice at 60 fps alternates repeats and changes. Consistent
/// similarities on both phases can be caused by still scenes or subtle 60 fps motion.
struct RepeatedFrameCadence {
    private static let currentPhaseMask: UInt32 = 0x5555_5555
    private static let window = UInt32.bitWidth
    private var history: UInt32 = 0
    private var count = 0
    private(set) var isHalfRate = false

    mutating func observe(nearRepeat: Bool) -> Bool {
        let previousWasNearRepeat = history & 1 != 0
        history = (history << 1) | (nearRepeat ? 1 : 0)
        count = min(count + 1, Self.window)
        guard count == Self.window else { return false }

        let currentRepeats = (history & Self.currentPhaseMask).nonzeroBitCount
        let otherRepeats = history.nonzeroBitCount - currentRepeats
        // Hysteresis: enter on a clear pattern, leave only when the repeats have mostly stopped.
        if isHalfRate {
            if max(currentRepeats, otherRepeats) < 8 { isHalfRate = false }
        } else if (currentRepeats >= 12 && otherRepeats <= 3) || (otherRepeats >= 12 && currentRepeats <= 3) {
            isHalfRate = true
        }
        return isHalfRate && nearRepeat && !previousWasNearRepeat
    }
}

/// 64x36 luma samples of a 420v frame, read on the CPU straight from the IOSurface
/// (~2.3 k bytes: microseconds, no GPU round trip). Used to spot repeated frames.
struct LumaThumbnail {
    static let columns = 64, rows = 36
    var samples: [UInt8]

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let tenBit = !PixelFormats.is8Bit420(buffer)
        var out = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        for r in 0..<Self.rows {
            let y = r * h / Self.rows
            for c in 0..<Self.columns {
                let x = c * w / Self.columns
                if tenBit {
                    let v = base.advanced(by: y * stride + x * 2).assumingMemoryBound(to: UInt16.self).pointee
                    out[r * Self.columns + c] = UInt8(v >> 8)
                } else {
                    out[r * Self.columns + c] = base.advanced(by: y * stride + x).assumingMemoryBound(to: UInt8.self).pointee
                }
            }
        }
        samples = out
    }

    /// Normalised SAD in [0, 1].
    func sad(_ other: LumaThumbnail) -> Double {
        var sum = 0
        for i in 0..<samples.count { sum += abs(Int(samples[i]) - Int(other.samples[i])) }
        return Double(sum) / (255.0 * Double(samples.count))
    }
}
