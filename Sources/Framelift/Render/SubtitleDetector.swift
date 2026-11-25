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
