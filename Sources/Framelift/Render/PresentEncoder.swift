// SPDX-License-Identifier: AGPL-3.0-only
// The final present: one 4:2:0 frame -> aspect-fit, letterboxed bgra8Unorm RGB plus the HUD,
// encoded into the caller's command buffer. Upscales use the Sharp (Catmull-Rom + adaptive
// sharpening) or Bilinear pass. Confined to one thread.
import CoreVideo
import Foundation
import Metal

/// The method one present actually used.
enum UpscaleMethod: String, Sendable {
    case bilinear, sharp
}

final class PresentEncoder: @unchecked Sendable {
    /// Strength of the sharp pass's adaptive sharpening (0 = plain Catmull-Rom).
    var sharpness: Float = Float(StreamSettingsLimits.defaultSharpness)
    /// Matrix + range of the YUV->RGB step (the presenter sets it per stream format and colour mode).
    var colour = ColourMapping.standard {
        didSet { if colour != oldValue { constants = Self.makeConstants(colour) } }
    }
    private var constants = PresentEncoder.makeConstants(.standard)

    private let bilinearPipeline: MTLRenderPipelineState
    private let sharpPipeline: MTLRenderPipelineState
    private let hudPipeline: MTLRenderPipelineState
    private let ctx: RenderContext

    init(context: RenderContext, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        ctx = context
        func pipeline(_ label: String, _ fragment: String, blend: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            guard let v = context.library.makeFunction(name: "present_vertex") else { throw RenderError.missingFunction("present_vertex") }
            guard let f = context.library.makeFunction(name: fragment) else { throw RenderError.missingFunction(fragment) }
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = pixelFormat
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try context.device.makeRenderPipelineState(descriptor: d)
        }
        bilinearPipeline = try pipeline("framelift.present", "present_fragment")
        sharpPipeline = try pipeline("framelift.present.sharp", "present_sharp_fragment")
        hudPipeline = try pipeline("framelift.hud", "hud_fragment", blend: true)
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

    /// Encodes `frame` into `target` (cleared to black outside the picture) and the HUD.
    /// Returns the method used, or nil if nothing was encoded. The command buffer retains every
    /// texture it uses; the caller keeps `keep` (the CVMetalTextures) alive until it completes.
    func encode(_ frame: CVPixelBuffer, into target: MTLTexture, commandBuffer cb: MTLCommandBuffer,
                hud: MTLTexture?) -> (method: UpscaleMethod, keep: [AnyObject])? {
        guard let (yTex, cTex, keep) = ctx.yuvTextures(frame) else { return nil }
        let dw = target.width, dh = target.height
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        let fit = Self.fitRect(frame: fw, fh, target: dw, dh)
        let isUpscale = fit.w > fw || fit.h > fh
        let method: UpscaleMethod = isUpscale ? .sharp : .bilinear

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.label = "framelift.present.\(method.rawValue)"
        enc.setViewport(MTLViewport(originX: Double(fit.x), originY: Double(fit.y), width: Double(fit.w), height: Double(fit.h), znear: 0, zfar: 1))
        enc.setRenderPipelineState(method == .sharp ? sharpPipeline : bilinearPipeline)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        var k = PixelFormats.is8Bit420(frame) ? constants.eight : constants.ten
        k.params.x = sharpness
        enc.setFragmentBytes(&k, length: MemoryLayout<PresentColourConstants>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let text = hud {
            let dwD = Double(dw), dhD = Double(dh)
            let scale = max(2, (dhD / 360).rounded(.down))
            let w = Double(text.width) * scale, h = Double(text.height) * scale
            let margin = (dhD * 0.02).rounded()
            enc.setViewport(MTLViewport(originX: margin, originY: margin, width: min(w, dwD - margin), height: min(h, dhD - margin), znear: 0, zfar: 1))
            enc.setRenderPipelineState(hudPipeline)
            enc.setFragmentTexture(text, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        return (method, keep)
    }
}
