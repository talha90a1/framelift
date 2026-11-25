// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Vision

final class SubtitleDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "framelift.subtitles", qos: .utility)
    private let lock = NSLock()
    private var cached: [SIMD4<Float>] = []
    private var observedAt: Double = 0
    private var requestedAt: Double = -1
    private var busy = false
    private var generation = 0

    func regions(for buffer: CVPixelBuffer, at now: Double) -> [SIMD4<Float>] {
        lock.lock()
        let result = now - observedAt < 0.7 ? cached : []
        let request = !busy && now - requestedAt >= 0.25
        let current = generation
        if request { busy = true; requestedAt = now }
        lock.unlock()
        if request {
            queue.async { [self] in
                let regions = (try? Self.detect(in: buffer)) ?? []
                lock.withLock {
                    if current == generation { cached = regions; observedAt = now }
                    busy = false
                }
            }
        }
        return result
    }

    func reset() {
        lock.withLock { generation += 1; cached = []; observedAt = 0; requestedAt = -1 }
    }

    static func detect(in buffer: CVPixelBuffer) throws -> [SIMD4<Float>] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        request.regionOfInterest = CGRect(x: 0.15, y: 0.02, width: 0.7, height: 0.23)
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.35,
                  text.string.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { return nil }
            let local = observation.boundingBox
            let roi = request.regionOfInterest
            let r = CGRect(x: roi.minX + local.minX * roi.width, y: roi.minY + local.minY * roi.height,
                           width: local.width * roi.width, height: local.height * roi.height)
            guard r.midX > 0.25, r.midX < 0.75, r.height < 0.065,
                  text.string.filter({ $0.isLetter }).count >= 5 || abs(r.midX - 0.5) < 0.08 else { return nil }
            let dx = 3 / Double(CVPixelBufferGetWidth(buffer))
            let dy = 2 / Double(CVPixelBufferGetHeight(buffer))
            return SIMD4(Float(max(0, min(0.18, r.minX - dx))), Float(max(0, 1 - r.maxY - dy)),
                         Float(min(1, max(0.82, r.maxX + dx))), Float(min(1, 1 - r.minY + dy)))
        }.prefix(8).map { $0 }
    }
}

// Require the same compact, outlined three-arm shape in both real frames.
enum CrosshairDetector {
    static func regions(previous: CVPixelBuffer, current: CVPixelBuffer) -> [SIMD4<Float>] {
        let width = CVPixelBufferGetWidth(current), height = CVPixelBufferGetHeight(current)
        guard width >= 320, height >= 180,
              CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
              PixelFormats.is8Bit420(current) || PixelFormats.is10Bit420(current),
              CVPixelBufferGetWidth(previous) == width, CVPixelBufferGetHeight(previous) == height,
              CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
        guard CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(current, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddressOfPlane(previous, 0)?.assumingMemoryBound(to: UInt8.self),
              let b = CVPixelBufferGetBaseAddressOfPlane(current, 0)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let strideA = CVPixelBufferGetBytesPerRowOfPlane(previous, 0), strideB = CVPixelBufferGetBytesPerRowOfPlane(current, 0)
        let deep = PixelFormats.is10Bit420(current)
        func value(_ base: UnsafeMutablePointer<UInt8>, _ stride: Int, _ x: Int, _ y: Int) -> Int {
            if deep { return Int(UnsafeRawPointer(base.advanced(by: y * stride + x * 2)).load(as: UInt16.self) >> 8) }
            return Int(base[y * stride + x])
        }
        let scale = Double(height) / 1080
        let cx = width / 2, cy = height / 2, band = max(1, Int(scale.rounded()))
        let start = max(2, Int((3 * scale).rounded())), end = max(start + 4, Int((24 * scale).rounded()))
        let minLength = max(3, Int((6 * scale).rounded())), maxLength = max(minLength, Int((18 * scale).rounded()))

        func arm(_ direction: Int) -> (near: Int, far: Int, bounds: SIMD4<Int>, inkA: Double, inkB: Double)? {
            var points: [Int: [SIMD2<Int>]] = [:]
            for distance in start...end {
                for offset in -band..<band {
                    let horizontal = direction != 2
                    let x = horizontal ? cx + (direction == 0 ? -distance : distance) : cx + offset
                    let y = horizontal ? cy + offset : cy + distance
                    let left = horizontal ? SIMD2(x, cy - band - 1) : SIMD2(cx - band - 1, y)
                    let right = horizontal ? SIMD2(x, cy + band) : SIMD2(cx + band, y)
                    let av = value(a, strideA, x, y), bv = value(b, strideB, x, y)
                    guard av >= 80, bv >= 80, abs(av - bv) <= 48,
                          av - value(a, strideA, left.x, left.y) >= 18,
                          av - value(a, strideA, right.x, right.y) >= 18,
                          bv - value(b, strideB, left.x, left.y) >= 18,
                          bv - value(b, strideB, right.x, right.y) >= 18 else { continue }
                    points[distance, default: []].append(SIMD2(x, y))
                }
            }
            var runs: [ClosedRange<Int>] = [], runStart: Int?
            for distance in start...(end + 1) {
                if points[distance] != nil { if runStart == nil { runStart = distance } }
                else if let first = runStart { runs.append(first...(distance - 1)); runStart = nil }
            }
            guard let run = runs.filter({ $0.count >= minLength && $0.count <= maxLength }).max(by: { $0.count < $1.count }) else { return nil }
            let glyph = run.flatMap { points[$0] ?? [] }
            let padding = max(1, Int(scale.rounded()))
            return (run.lowerBound, run.upperBound,
                    SIMD4(glyph.map(\.x).min()! - padding, glyph.map(\.y).min()! - padding,
                          glyph.map(\.x).max()! + padding + 1, glyph.map(\.y).max()! + padding + 1),
                    glyph.reduce(0.0) { $0 + Double(value(a, strideA, $1.x, $1.y)) } / Double(glyph.count),
                    glyph.reduce(0.0) { $0 + Double(value(b, strideB, $1.x, $1.y)) } / Double(glyph.count))
        }

        guard let left = arm(0), let right = arm(1), let down = arm(2),
              abs(left.near - right.near) <= max(2, Int(3 * scale)),
              abs(left.far - right.far) <= max(2, Int(3 * scale)),
              abs(down.near - right.near) <= max(2, Int(3 * scale)),
              abs(down.far - right.far) <= max(3, Int(5 * scale)) else { return [] }
        let centre = (-band..<band).flatMap { y in (-band..<band).map { x in SIMD2(cx + x, cy + y) } }
        let centreA = centre.reduce(0.0) { $0 + Double(value(a, strideA, $1.x, $1.y)) } / Double(centre.count)
        let centreB = centre.reduce(0.0) { $0 + Double(value(b, strideB, $1.x, $1.y)) } / Double(centre.count)
        let inkA = (left.inkA + right.inkA + down.inkA) / 3, inkB = (left.inkB + right.inkB + down.inkB) / 3
        guard abs(centreA - inkA) > 24 || abs(centreB - inkB) > 24 else { return [] }
        return [left.bounds, right.bounds, down.bounds].map {
            SIMD4(Float($0.x) / Float(width), Float($0.y) / Float(height), Float($0.z) / Float(width), Float($0.w) / Float(height))
        }
    }
}
