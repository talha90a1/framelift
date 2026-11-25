// SPDX-License-Identifier: AGPL-3.0-only
// Restores subtitles, crosshairs and stable HUD pixels in generated frames.
import CoreVideo
import Foundation
import Metal

final class FrameBlender: @unchecked Sendable {
    private let ctx: RenderContext
    private let subtitlePSO: MTLComputePipelineState
    private let lock = NSLock()
    private var size: (Int, Int, OSType)?
    private var pool: CVPixelBufferPool?

    init(context: RenderContext) throws {
        ctx = context
        subtitlePSO = try context.compute("protect_subtitles")
    }

    func keepSubtitles(previous: CVPixelBuffer, current: CVPixelBuffer, generated: CVPixelBuffer,
                       regions: [SIMD4<Float>], hudRegions: [SIMD4<Float>] = [], completion: @escaping (CVPixelBuffer?) -> Void) {
        let text = Array(regions.prefix(5))
        let glyphs = CrosshairDetector.regions(previous: previous, current: current)
        let protected = text + glyphs + Array(hudRegions.prefix(4))
        guard !protected.isEmpty else { completion(generated); return }
        guard let g = ctx.yuvTextures(generated) else { completion(nil); return }
        run(previous: previous, current: current, extra: g, regions: protected,
            textCount: text.count, reticleEnd: text.count + glyphs.count, completion: completion)
    }

    private func run(previous: CVPixelBuffer, current: CVPixelBuffer,
                     extra: (y: MTLTexture, c: MTLTexture, keep: [CVMetalTexture]), regions: [SIMD4<Float>], textCount: Int, reticleEnd: Int,
                     completion: @escaping (CVPixelBuffer?) -> Void) {
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        let format = CVPixelBufferGetPixelFormatType(current)
        guard CVPixelBufferGetPixelFormatType(previous) == format else { completion(nil); return }
        let deep = PixelFormats.is10Bit420(current)
        lock.lock()
        if size.map({ $0 != (w, h, format) }) ?? true {
            size = (w, h, format)
            pool = PixelFormats.makePool(width: w, height: h, minimum: 12, format: format)
        }
        let pool = self.pool
        lock.unlock()
        var out: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
        guard let out, CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h,
              let a = ctx.yuvTextures(previous), let b = ctx.yuvTextures(current),
              let yOut = ctx.writablePlaneTexture(out, plane: 0, format: deep ? .r16Unorm : .r8Unorm),
              let cOut = ctx.writablePlaneTexture(out, plane: 1, format: deep ? .rg16Unorm : .rg8Unorm),
              let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { completion(nil); return }
        cb.label = "framelift.protectSubtitles"
        enc.setComputePipelineState(subtitlePSO)
        var count = UInt32(min(12, regions.count))
        enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 0)
        var boxes = regions.prefix(12).map { box in
            SIMD4(Float(ceil(Double(box.x) * Double(w) - 0.5)), Float(ceil(Double(box.y) * Double(h) - 0.5)),
                  Float(floor(Double(box.z) * Double(w) - 0.5) + 1), Float(floor(Double(box.w) * Double(h) - 0.5) + 1))
        }
        boxes += Array(repeating: SIMD4<Float>.zero, count: 12 - boxes.count)
        enc.setBytes(&boxes, length: MemoryLayout<SIMD4<Float>>.stride * 12, index: 1)
        var textCount = UInt32(textCount)
        enc.setBytes(&textCount, length: MemoryLayout<UInt32>.size, index: 2)
        var reticleEnd = UInt32(reticleEnd)
        enc.setBytes(&reticleEnd, length: MemoryLayout<UInt32>.size, index: 3)
        enc.setTexture(a.y, index: 0); enc.setTexture(b.y, index: 1)
        enc.setTexture(a.c, index: 2); enc.setTexture(b.c, index: 3)
        enc.setTexture(yOut, index: 5); enc.setTexture(cOut, index: 6)
        enc.setTexture(extra.y, index: 4); enc.setTexture(extra.c, index: 7)
        let tw = subtitlePSO.threadExecutionWidth
        let th = max(1, subtitlePSO.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: cOut.width, height: cOut.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 8), depth: 1))
        enc.endEncoding()
        CVBufferPropagateAttachments(current, out)
        let keep: [AnyObject] = a.keep + b.keep + extra.keep + [yOut, cOut, previous, current]
        cb.addCompletedHandler { cb in
            withExtendedLifetime(keep) {}
            completion(cb.status == .completed ? out : nil)
        }
        cb.commit()
    }
}
