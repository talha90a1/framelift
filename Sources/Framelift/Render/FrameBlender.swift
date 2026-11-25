// SPDX-License-Identifier: AGPL-3.0-only
// Motion-free 50/50 blend of two 4:2:0 frames (stands in when Apple's interpolated frame is late),
// and the static-overlay guard applied to Apple's frame.
import CoreVideo
import Foundation
import Metal

final class FrameBlender: @unchecked Sendable {
    private let ctx: RenderContext
    private let pso: MTLComputePipelineState
    private let staticPSO: MTLComputePipelineState
    private let subtitlePSO: MTLComputePipelineState
    private let lock = NSLock()
    private var size: (Int, Int)?
    private var pool: CVPixelBufferPool?

    init(context: RenderContext) throws {
        ctx = context
        pso = try context.compute("blend_frames")
        staticPSO = try context.compute("keep_static")
        subtitlePSO = try context.compute("protect_subtitles")
    }

    /// Copies pixels that are unchanged between the real frames (subtitles, HUD) into Apple's
    /// generated frame. Asynchronous, ~0.2 ms GPU; `completion` gets nil on failure.
    func keepStatic(previous: CVPixelBuffer, current: CVPixelBuffer, generated: CVPixelBuffer, completion: @escaping (CVPixelBuffer?) -> Void) {
        guard let g = ctx.yuvTextures(generated) else { completion(nil); return }
        run(staticPSO, previous: previous, current: current, extra: g, completion: completion)
    }

    func keepSubtitles(previous: CVPixelBuffer, current: CVPixelBuffer, generated: CVPixelBuffer,
                       regions: [SIMD4<Float>], completion: @escaping (CVPixelBuffer?) -> Void) {
        let text = Array(regions.prefix(5))
        let glyphs = CrosshairDetector.regions(previous: previous, current: current)
        let protected = text + glyphs
        guard !protected.isEmpty else { completion(generated); return }
        guard let g = ctx.yuvTextures(generated) else { completion(nil); return }
        run(subtitlePSO, previous: previous, current: current, extra: g, regions: protected, textCount: text.count, completion: completion)
    }

    /// Asynchronous, ~0.1 ms GPU; `completion` gets nil on failure.
    func blend(previous: CVPixelBuffer, current: CVPixelBuffer, completion: @escaping (CVPixelBuffer?) -> Void) {
        run(pso, previous: previous, current: current, extra: nil, completion: completion)
    }

    private func run(_ pso: MTLComputePipelineState, previous: CVPixelBuffer, current: CVPixelBuffer,
                     extra: (y: MTLTexture, c: MTLTexture, keep: [CVMetalTexture])?, regions: [SIMD4<Float>] = [], textCount: Int = 0,
                     completion: @escaping (CVPixelBuffer?) -> Void) {
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        lock.lock()
        if size.map({ $0 != (w, h) }) ?? true {
            size = (w, h)
            pool = PixelFormats.makePool(width: w, height: h, minimum: 12)
        }
        let pool = self.pool
        lock.unlock()
        var out: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
        guard let out, CVPixelBufferGetWidth(previous) == w, CVPixelBufferGetHeight(previous) == h,
              let a = ctx.yuvTextures(previous), let b = ctx.yuvTextures(current),
              let yOut = ctx.writablePlaneTexture(out, plane: 0, format: .r8Unorm),
              let cOut = ctx.writablePlaneTexture(out, plane: 1, format: .rg8Unorm),
              let cb = ctx.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { completion(nil); return }
        cb.label = extra == nil ? "framelift.blend" : (regions.isEmpty ? "framelift.keepStatic" : "framelift.protectSubtitles")
        enc.setComputePipelineState(pso)
        var count = UInt32(min(8, regions.count))
        enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 0)
        var boxes = regions.prefix(8).map { box in
            SIMD4(Float(ceil(Double(box.x) * Double(w) - 0.5)), Float(ceil(Double(box.y) * Double(h) - 0.5)),
                  Float(floor(Double(box.z) * Double(w) - 0.5) + 1), Float(floor(Double(box.w) * Double(h) - 0.5) + 1))
        }
        boxes += Array(repeating: SIMD4<Float>.zero, count: 8 - boxes.count)
        enc.setBytes(&boxes, length: MemoryLayout<SIMD4<Float>>.stride * 8, index: 1)
        var textCount = UInt32(textCount)
        enc.setBytes(&textCount, length: MemoryLayout<UInt32>.size, index: 2)
        enc.setTexture(a.y, index: 0); enc.setTexture(b.y, index: 1)
        enc.setTexture(a.c, index: 2); enc.setTexture(b.c, index: 3)
        enc.setTexture(yOut, index: 5); enc.setTexture(cOut, index: 6)
        if let extra { enc.setTexture(extra.y, index: 4); enc.setTexture(extra.c, index: 7) }
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: cOut.width, height: cOut.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 8), depth: 1))
        enc.endEncoding()
        let keep: [AnyObject] = a.keep + b.keep + (extra?.keep ?? []) + [yOut, cOut, previous, current]
        cb.addCompletedHandler { cb in
            withExtendedLifetime(keep) {}
            completion(cb.status == .completed ? out : nil)
        }
        cb.commit()
    }
}
