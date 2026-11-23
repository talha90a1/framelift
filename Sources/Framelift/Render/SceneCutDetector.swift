// SPDX-License-Identifier: AGPL-3.0-only
// GPU shot-change test (port of Veyra's VfgShotChange.hlsl / SceneCadenceAnalyzer thresholds).
// Runs in parallel with interpolation; the result is read when the pair is about to be shown.
import CoreVideo
import Foundation
import Metal

private struct SceneCutParams {
    var width: UInt32
    var height: UInt32
    var compare: UInt32
    var videoRange: UInt32
    var cutSad: Float = 0.3
    var cutHistogram: Float = 0.5
    var replacementSad: Float = 0.08
    var replacementHistogram: Float = 0.9
    var flashSad: Float = 0.5
    var flashHistogram: Float = 0.1
    var pad1: Float = 0
    var pad2: Float = 0
}

struct SceneCutResult {
    var isCut: Bool
    var sad: Float
    var histogramDistance: Float
}

final class SceneCutDetector: @unchecked Sendable {
    private let ctx: RenderContext
    private let pso: MTLComputePipelineState
    private let buffers: [MTLBuffer]
    private var nextBuffer = 0
    private let lock = NSLock()

    init(context: RenderContext) throws {
        ctx = context
        pso = try context.compute("scene_cut")
        buffers = (0..<4).map { _ in context.device.makeBuffer(length: 16, options: .storageModeShared)! }
    }

    /// Encodes the test into `cb`; `result()` is valid after the buffer completes.
    func encode(previous: CVPixelBuffer, current: CVPixelBuffer, into cb: MTLCommandBuffer) -> (() -> SceneCutResult)? {
        guard let (a, _, keepA) = ctx.yuvTextures(previous),
              let (b, _, keepB) = ctx.yuvTextures(current),
              a.width == b.width, a.height == b.height,
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        let out = lock.withLock {
            let buffer = buffers[nextBuffer]
            nextBuffer = (nextBuffer + 1) % buffers.count
            return buffer
        }
        let format = CVPixelBufferGetPixelFormatType(current)
        let full = format == PixelFormats.fullRange420 || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var p = SceneCutParams(width: UInt32(a.width), height: UInt32(a.height), compare: 1, videoRange: full ? 0 : 1)
        enc.setComputePipelineState(pso)
        enc.setTexture(a, index: 0)
        enc.setTexture(b, index: 1)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<SceneCutParams>.stride, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.addCompletedHandler { _ in withExtendedLifetime((keepA, keepB)) {} }
        return {
            let w = out.contents().assumingMemoryBound(to: UInt32.self)
            return SceneCutResult(isCut: w[0] != 0, sad: Float(bitPattern: w[1]), histogramDistance: Float(bitPattern: w[2]))
        }
    }

    /// Standalone asynchronous test on the render queue.
    func detect(previous: CVPixelBuffer, current: CVPixelBuffer, completion: @escaping (SceneCutResult?) -> Void) {
        guard let cb = ctx.queue.makeCommandBuffer(), let read = encode(previous: previous, current: current, into: cb) else {
            completion(nil); return
        }
        cb.label = "framelift.scene-cut"
        cb.addCompletedHandler { cb in completion(cb.status == .completed ? read() : nil) }
        cb.commit()
    }
}
