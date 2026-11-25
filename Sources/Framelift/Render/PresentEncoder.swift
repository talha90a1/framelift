// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Metal
import MetalFX

/// The method one present actually used.
enum UpscaleMethod: String, Sendable {
    case bilinear, sharp, metalFX
}

final class PresentEncoder: @unchecked Sendable {
    /// Strength of the sharp pass's adaptive sharpening (0 = plain Catmull-Rom).
    var sharpness: Float = Float(StreamSettingsLimits.defaultSharpness)
    var upscaler: Upscaler = .sharp
    /// Matrix + range of the YUV->RGB step (the presenter sets it per stream format and colour mode).
    var colour = ColourMapping.standard {
        didSet { if colour != oldValue { constants = Self.makeConstants(colour) } }
    }
    private var constants = PresentEncoder.makeConstants(.standard)

    private struct Pipelines {
        var bilinear, sharp, copy, hud: MTLRenderPipelineState
    }
    /// Render pipelines cached by target pixel format.
    private var pipelines: [MTLPixelFormat: Pipelines] = [:]

    private struct ScalerKey: Equatable {
        var inWidth, inHeight, outWidth, outHeight: Int
        var format: MTLPixelFormat
    }
    private struct SpatialScaler {
        let key: ScalerKey
        let scaler: MTLFXSpatialScaler
        let input, output: MTLTexture
    }
    private var scaler: SpatialScaler?
    /// A size and format MetalFX refused; the sharp pass is used for it.
    private var refusedScaler: ScalerKey?

    private let ctx: RenderContext

    init(context: RenderContext) throws {
        ctx = context
        _ = try pipelines(for: .bgra8Unorm)
    }

    private func pipelines(for format: MTLPixelFormat) throws -> Pipelines {
        if let p = pipelines[format] { return p }
        func pipeline(_ fragment: String, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = "framelift.\(fragment)"
            guard let v = ctx.library.makeFunction(name: "present_vertex") else { throw RenderError.missingFunction("present_vertex") }
            guard let f = ctx.library.makeFunction(name: fragment) else { throw RenderError.missingFunction(fragment) }
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = format
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try ctx.device.makeRenderPipelineState(descriptor: d)
        }
        let p = Pipelines(
            bilinear: try pipeline("present_fragment"), sharp: try pipeline("present_sharp_fragment"),
            copy: try pipeline("copy_fragment"), hud: try pipeline("hud_fragment", blend: true))
        pipelines[format] = p
        return p
    }

    /// 8-bit and 10-bit variants (offsets differ slightly per bit depth), computed once per mapping.
    private static func makeConstants(_ m: ColourMapping) -> (eight: PresentColourConstants, ten: PresentColourConstants) {
        (m.constants(tenBit: false), m.constants(tenBit: true))
    }

    /// Aspect-fit rectangle of a `fw`x`fh` frame in a `dw`x`dh` target (whole pixels).
    static func fitRect(frame fw: Int, _ fh: Int, target dw: Int, _ dh: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let scale = min(Double(dw) / Double(fw), Double(dh) / Double(fh))
        let w = Int((Double(fw) * scale).rounded()), h = Int((Double(fh) * scale).rounded())
        return (Int((Double(dw - w) / 2).rounded()), Int((Double(dh - h) / 2).rounded()), w, h)
    }

    private func spatialScaler(_ key: ScalerKey) -> SpatialScaler? {
        if let scaler, scaler.key == key { return scaler }
        if refusedScaler == key { return nil }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = key.inWidth
        d.inputHeight = key.inHeight
        d.outputWidth = key.outWidth
        d.outputHeight = key.outHeight
        d.colorTextureFormat = key.format
        d.outputTextureFormat = key.format
        // SDR and PQ/HLG values are both perceptually coded in 0...1.
        d.colorProcessingMode = .perceptual
        func texture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture? {
            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: key.format, width: w, height: h, mipmapped: false)
            t.usage = usage
            t.storageMode = .private
            return ctx.device.makeTexture(descriptor: t)
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(ctx.device), let s = d.makeSpatialScaler(device: ctx.device),
            let input = texture(key.inWidth, key.inHeight, [.renderTarget, .shaderRead, s.colorTextureUsage]),
            let output = texture(key.outWidth, key.outHeight, [.shaderRead, s.outputTextureUsage])
        else {
            refusedScaler = key
            Diagnostics.shared.event("render: MetalFX refused \(key.inWidth)x\(key.inHeight) -> \(key.outWidth)x\(key.outHeight), using the sharp pass")
            return nil
        }
        s.colorTexture = input
        s.outputTexture = output
        s.inputContentWidth = key.inWidth
        s.inputContentHeight = key.inHeight
        scaler = SpatialScaler(key: key, scaler: s, input: input, output: output)
        return scaler
    }

    /// Retain the returned CVMetalTextures until the command buffer completes.
    func encode(
        _ frame: CVPixelBuffer, into target: MTLTexture, commandBuffer cb: MTLCommandBuffer,
        hud: MTLTexture?
    ) -> (method: UpscaleMethod, keep: [AnyObject])? {
        guard let (yTex, cTex, keep) = ctx.yuvTextures(frame), let p = try? pipelines(for: target.pixelFormat) else { return nil }
        let dw = target.width, dh = target.height
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        let fit = Self.fitRect(frame: fw, fh, target: dw, dh)
        let isUpscale = fit.w > fw || fit.h > fh
        var k = PixelFormats.is8Bit420(frame) ? constants.eight : constants.ten
        k.params.x = sharpness

        var scaled: MTLTexture?
        if isUpscale, upscaler == .metalFX,
            let s = spatialScaler(
                ScalerKey(
                    inWidth: fw, inHeight: fh, outWidth: fit.w, outHeight: fit.h,
                    format: .bgra8Unorm)),
            let rgb = try? pipelines(for: s.input.pixelFormat)
        {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = s.input
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
            enc.label = "framelift.present.rgb"
            enc.setRenderPipelineState(rgb.bilinear)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(cTex, index: 1)
            enc.setFragmentBytes(&k, length: MemoryLayout<PresentColourConstants>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            s.scaler.encode(commandBuffer: cb)
            scaled = s.output
        }
        let method: UpscaleMethod
        if scaled != nil {
            method = .metalFX
        } else {
            method = isUpscale ? .sharp : .bilinear
        }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.label = "framelift.present.\(method.rawValue)"
        enc.setViewport(MTLViewport(originX: Double(fit.x), originY: Double(fit.y), width: Double(fit.w), height: Double(fit.h), znear: 0, zfar: 1))
        if let scaled {
            enc.setRenderPipelineState(p.copy)
            enc.setFragmentTexture(scaled, index: 0)
        } else {
            enc.setRenderPipelineState(method == .sharp ? p.sharp : p.bilinear)
            enc.setFragmentTexture(yTex, index: 0)
            enc.setFragmentTexture(cTex, index: 1)
            enc.setFragmentBytes(&k, length: MemoryLayout<PresentColourConstants>.stride, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let text = hud {
            let dwD = Double(dw), dhD = Double(dh)
            let margin = (dhD * 0.02).rounded()
            let availableWidth = max(1, dwD - 2 * margin), availableHeight = max(1, dhD - 2 * margin)
            let scale = min(max(2, (dhD / 360).rounded(.down)), availableWidth / Double(text.width), availableHeight / Double(text.height))
            let w = Double(text.width) * scale, h = Double(text.height) * scale
            enc.setViewport(MTLViewport(originX: margin, originY: margin, width: w, height: h, znear: 0, zfar: 1))
            enc.setRenderPipelineState(p.hud)
            enc.setFragmentTexture(text, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        return (method, keep)
    }
}
