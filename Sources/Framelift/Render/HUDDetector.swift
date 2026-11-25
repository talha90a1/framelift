// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation

final class HUDDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "framelift.hud", qos: .utility)
    private let lock = NSLock()
    private var cached: [SIMD4<Float>] = []
    private var observedAt = -1.0
    private var requestedAt = -1.0
    private var busy = false
    private var generation = 0

    func regions(previous: CVPixelBuffer, current: CVPixelBuffer, at now: Double) -> [SIMD4<Float>] {
        lock.lock()
        let result = now - observedAt < 0.7 ? cached : []
        let request = !busy && now - requestedAt >= 0.25
        let gen = generation
        if request { busy = true; requestedAt = now }
        lock.unlock()
        if request {
            queue.async { [self] in
                let regions = Self.detect(previous: previous, current: current)
                lock.withLock {
                    if gen == generation { cached = regions; observedAt = now }
                    busy = false
                }
            }
        }
        return result
    }

    func reset() {
        lock.withLock {
            generation += 1; cached = []; observedAt = -1; requestedAt = -1
        }
    }

    static func detect(previous: CVPixelBuffer, current: CVPixelBuffer) -> [SIMD4<Float>] {
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        guard w >= 320, h >= 180,
            CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h,
            CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
            PixelFormats.is8Bit420(current) || PixelFormats.is10Bit420(current),
            CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess
        else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
        guard CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(current, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddressOfPlane(previous, 0),
            let b = CVPixelBufferGetBaseAddressOfPlane(current, 0)
        else { return [] }
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(previous, 0)
        let strideB = CVPixelBufferGetBytesPerRowOfPlane(current, 0)
        let deep = PixelFormats.is10Bit420(current)
        func value(_ base: UnsafeMutableRawPointer, _ stride: Int, _ x: Int, _ y: Int) -> Int {
            if deep { return Int(base.load(fromByteOffset: y * stride + x * 2, as: UInt16.self) >> 8) }
            return Int(base.load(fromByteOffset: y * stride + x, as: UInt8.self))
        }
        struct Edge {
            let x: Int, end: Int, y: Int, sign: Int
            var width: Int { end - x }
        }
        let step = max(1, h / 540), minWidth = max(20, w / 25)
        var boxes: [SIMD4<Int>] = []
        for y0 in [0, h * 4 / 5] {
            for x0 in [0, w * 3 / 4] {
                let x1 = min(w - step, x0 + w / 4)
                let y1 = min(h, y0 + h / 5)
                var edges: [Edge] = []
                for y in stride(from: y0 + step * 2, to: y1, by: step) {
                    var start = x0, last = x0, sign = 0, gap = 0
                    func append() {
                        if last - start >= minWidth {
                            edges.append(Edge(x: start, end: last + step, y: y, sign: sign))
                        }
                    }
                    for x in stride(from: x0, to: x1, by: step) {
                        let v = value(b, strideB, x, y)
                        let delta = v - value(b, strideB, x, y - step * 2)
                        let direction = delta >= 12 ? 1 : (delta <= -12 ? -1 : 0)
                        let stable = abs(value(a, strideA, x, y) - v) <= 8
                        if stable && direction != 0 {
                            if sign != direction || gap > 2 {
                                append(); start = x; sign = direction
                            }
                            last = x; gap = 0
                        } else {
                            gap += 1
                        }
                    }
                    append()
                }
                edges.sort { $0.width > $1.width }
                for top in edges {
                    guard boxes.count < 4 else { break }
                    for bottom in edges where bottom.sign != top.sign {
                        let height = bottom.y - top.y
                        let left = min(top.x, bottom.x), right = max(top.end, bottom.end)
                        let overlap = min(top.end, bottom.end) - max(top.x, bottom.x)
                        let aligned = abs(top.x - bottom.x) <= step * 3 || abs(top.end - bottom.end) <= step * 3
                        guard height >= max(4, h / 180), height <= h / 20, right - left >= height * 3,
                            overlap >= minWidth, aligned,
                            !boxes.contains(where: { left < $0.z && right > $0.x && top.y < $0.w && bottom.y > $0.y })
                        else { continue }
                        var stable = 0, total = 0
                        for y in stride(from: top.y, through: bottom.y, by: step) {
                            for x in stride(from: left, to: right, by: step) {
                                total += 1
                                if abs(value(a, strideA, x, y) - value(b, strideB, x, y)) <= 8 { stable += 1 }
                            }
                        }
                        guard stable * 10 >= total * 9 else { continue }
                        // Include adjacent meter icons; the shader copies only stable pixels.
                        boxes.append(
                            SIMD4(
                                max(0, left - height * 3), max(0, top.y - height),
                                min(w, right + height * 3), min(h, bottom.y + height)))
                        break
                    }
                }
            }
        }
        return boxes.map { SIMD4(Float($0.x) / Float(w), Float($0.y) / Float(h), Float($0.z) / Float(w), Float($0.w) / Float(h)) }
    }
}
