// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

final class HDRColorConverter: @unchecked Sendable {
    private let context: RenderContext
    private let decode: MTLComputePipelineState
    private let encode: MTLComputePipelineState
    private let rescaleFlow: MTLComputePipelineState
    private let scaler: MPSImageBilinearScale
    private let lock = NSLock()
    private var pools: [String: CVPixelBufferPool] = [:]

    init(context: RenderContext) throws {
        self.context = context
        decode = try context.compute("hdr_to_rgb")
        encode = try context.compute("rgb_to_hdr")
        rescaleFlow = try context.compute("rescale_hdr_flow")
        scaler = MPSImageBilinearScale(device: context.device)
    }

    func makeRGB(width: Int, height: Int) -> CVPixelBuffer? {
        makeBuffer(width: width, height: height, format: kCVPixelFormatType_64RGBAHalf)
    }

    func scaledMotion(_ input: CVPixelBuffer, width: Int, height: Int, command: MTLCommandBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(input) == width, CVPixelBufferGetHeight(input) == height { return input }
        guard let out = makeRGB(width: width, height: height),
            let source = context.rgbaTexture(input), let destination = context.rgbaTexture(out)
        else { return nil }
        scaler.encode(commandBuffer: command, sourceTexture: source.0, destinationTexture: destination.0)
        CVBufferPropagateAttachments(input, out)
        command.addCompletedHandler { _ in withExtendedLifetime((source.1, destination.1, input)) {} }
        return out
    }

    func rescaleFlow(_ input: CVPixelBuffer, into output: CVPixelBuffer, command: MTLCommandBuffer) -> Bool {
        guard let source = context.flowTexture(input), let destination = context.flowTexture(output),
            let enc = command.makeComputeCommandEncoder()
        else { return false }
        enc.setComputePipelineState(rescaleFlow)
        enc.setTexture(source.0, index: 0); enc.setTexture(destination.0, index: 1)
        dispatch(enc, pipeline: rescaleFlow, width: destination.0.width, height: destination.0.height)
        enc.endEncoding()
        command.addCompletedHandler { _ in withExtendedLifetime((source.1, destination.1, input, output)) {} }
        return true
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height):\(format)"
        let pool = lock.withLock { () -> CVPixelBufferPool? in
            if let pool = pools[key] { return pool }
            let pool = PixelFormats.makePool(width: width, height: height, minimum: 6, format: format)
            pools[key] = pool
            return pool
        }
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        return buffer
    }

    func motion(_ input: CVPixelBuffer, completion: @escaping (CVPixelBuffer?) -> Void) {
        // Use PQ/HLG code values to keep perceptual contrast in the motion model.
        let tags = ColourTags.read(input)
        guard PixelFormats.is10Bit420(input), CVPixelBufferGetWidth(input).isMultiple(of: 2),
            CVPixelBufferGetHeight(input).isMultiple(of: 2), tags.hdrCurve != nil,
            let out = makeRGB(width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input)),
            let planes = context.yuvTextures(input), let rgb = context.rgbaTexture(out),
            let cb = context.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder()
        else { completion(nil); return }
        var constants = ColourMapping.decide(tags, mode: .automatic).constants(tenBit: true)
        enc.setComputePipelineState(decode)
        enc.setTexture(planes.y, index: 0); enc.setTexture(planes.c, index: 1)
        enc.setTexture(rgb.0, index: 2)
        enc.setBytes(&constants, length: MemoryLayout<PresentColourConstants>.stride, index: 0)
        dispatch(enc, pipeline: decode, width: rgb.0.width, height: rgb.0.height)
        enc.endEncoding()
        CVBufferSetAttachment(
            out, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            out, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        let keep: [AnyObject] = planes.keep + [rgb.1, input]
        cb.addCompletedHandler { buffer in
            withExtendedLifetime(keep) {}
            completion(buffer.status == .completed ? out : nil)
        }
        cb.commit()
    }

    func encoded(
        _ input: CVPixelBuffer, matching source: CVPixelBuffer,
        completion: @escaping (CVPixelBuffer?) -> Void
    ) {
        let tags = ColourTags.read(source)
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        guard tags.hdrCurve != nil, PixelFormats.is10Bit420(source),
            CVPixelBufferGetWidth(input) == w, CVPixelBufferGetHeight(input) == h,
            let out = makeBuffer(width: w, height: h, format: CVPixelBufferGetPixelFormatType(source)),
            let rgb = context.rgbaTexture(input),
            let y = context.writablePlaneTexture(out, plane: 0, format: .r16Unorm),
            let c = context.writablePlaneTexture(out, plane: 1, format: .rg16Unorm),
            let cb = context.queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder()
        else { completion(nil); return }
        let mapping = ColourMapping.decide(tags, mode: .automatic)
        var constants = SIMD4<Float>(
            Float(mapping.matrix.weights.kr), Float(mapping.matrix.weights.kb),
            0, tags.fullRange ? 1 : 0)
        enc.setComputePipelineState(encode)
        enc.setTexture(rgb.0, index: 0)
        enc.setTexture(y, index: 1); enc.setTexture(c, index: 2)
        enc.setBytes(&constants, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        dispatch(enc, pipeline: encode, width: c.width, height: c.height)
        enc.endEncoding()
        CVBufferPropagateAttachments(source, out)
        let keep: [AnyObject] = [rgb.1, input, source, y, c]
        cb.addCompletedHandler { buffer in
            withExtendedLifetime(keep) {}
            completion(buffer.status == .completed ? out : nil)
        }
        cb.commit()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 8, depth: 1))
    }
}
