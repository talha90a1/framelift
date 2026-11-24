// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Metal
import Testing
@testable import Framelift

/// A 10-bit BT.2020 PQ frame through the real present path into a 10-bit (HDR drawable) target.
struct HDRPresentTests {
    private let pqTags = ColourTags(
        matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
        primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
        transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
        fullRange: false)

    @Test func pqAndHLGGetBT2100LayerSpacesWhateverTheMode() {
        for mode in ColourMode.allCases {
            let m = ColourMapping.decide(pqTags, mode: mode)
            #expect(m.matrix == .bt2020 && m.layer == LayerColourSpace(primaries: .bt2020, curve: .pq))
            #expect(m.layer.makeColorSpace()?.name == CGColorSpace.itur_2100_PQ)
        }
        var hlg = pqTags
        hlg.transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        let m = ColourMapping.decide(hlg, mode: .automatic)
        #expect(m.layer.isHDR && m.layer.makeColorSpace()?.name == CGColorSpace.itur_2100_HLG)
    }

    /// Video-range 10-bit Y'CbCr: 64 is black and 940 is white (code value 1.0 on the layer).
    @Test(arguments: [Upscaler.sharp, .metalFX])
    func tenBitVideoRangeMapsToFullCodeRange(upscaler: Upscaler) throws {
        let ctx = try RenderContext.shared()
        let encoder = try PresentEncoder(context: ctx)
        encoder.colour = ColourMapping.decide(pqTags, mode: .automatic)
        encoder.upscaler = upscaler
        let (fw, fh) = (64, 36)
        let (tw, th) = (128, 72)  // an upscale, so MetalFX runs when chosen
        for (y, expected) in [(940, 1023), (64, 0), (502, 511)] {
            let frame = try Self.frame(width: fw, height: fh, y: UInt16(y), c: 512)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm, width: tw, height: th, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            let target = try #require(ctx.device.makeTexture(descriptor: d))
            let cb = try #require(ctx.queue.makeCommandBuffer())
            let done = try #require(encoder.encode(frame, into: target, commandBuffer: cb, hud: nil))
            cb.commit()
            cb.waitUntilCompleted()
            withExtendedLifetime(done.keep) {}
            #expect(done.method == (upscaler == .metalFX ? .metalFX : .sharp))
            var pixel: UInt32 = 0
            target.getBytes(&pixel, bytesPerRow: tw * 4, from: MTLRegionMake2D(tw / 2, th / 2, 1, 1), mipmapLevel: 0)
            let (r, g, b) = ((pixel >> 20) & 0x3ff, (pixel >> 10) & 0x3ff, pixel & 0x3ff)
            for v in [r, g, b] {
                #expect(abs(Int(v) - expected) <= 3, "Y \(y) -> \(r),\(g),\(b), expected \(expected)")
            }
        }
    }

    /// An x420 (10-bit video range) IOSurface frame of one colour; samples sit in the top 10 bits.
    static func frame(width: Int, height: Int, y: UInt16, c: UInt16) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attrs as CFDictionary, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, value) in [(0, y), (1, c)] {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for row in 0..<rows {
                let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for i in 0..<(stride / 2) { p[i] = value << 6 }
            }
        }
        return buffer
    }
}
