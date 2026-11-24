// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Metal
import Testing
@testable import Framelift

struct ColourMappingTests {
    private let ps5SDR = ColourTags(
        matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
        primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
        transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
        fullRange: false)

    @Test func ps5SDRMapsToBT709VideoRangeSRGB() {
        let m = ColourMapping.decide(ps5SDR, mode: .automatic)
        #expect(m == ColourMapping.standard)
        #expect(!m.matrixAssumed && !m.layer.isHDR)
        #expect(m.layer.makeColorSpace()?.name == CGColorSpace.sRGB)
    }

    @Test func untaggedDefaultsTo709VideoSRGB() {
        let m = ColourMapping.decide(.untagged, mode: .automatic)
        #expect(m.matrix == .bt709 && !m.fullRange && m.layer == .sRGB && m.matrixAssumed)
    }

    @Test func matrixRangeAndPrimariesFollowTags() {
        var tags = ColourTags.untagged
        tags.matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        tags.fullRange = true
        let sd = ColourMapping.decide(tags, mode: .automatic)
        #expect(sd.matrix == .bt601 && sd.fullRange && sd.layer == .sRGB)

        tags = ColourTags(
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String, fullRange: false)
        let wide = ColourMapping.decide(tags, mode: .automatic)
        #expect(wide.matrix == .bt2020 && wide.layer == LayerColourSpace(primaries: .bt2020, curve: .sRGB) && !wide.layer.isHDR)
        #expect(wide.layer.makeColorSpace()?.name == CGColorSpace.itur_2020_sRGBGamma)

        tags.transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        let hdr = ColourMapping.decide(tags, mode: .automatic)
        #expect(hdr.layer == LayerColourSpace(primaries: .bt2020, curve: .pq) && hdr.layer.isHDR)
    }

    @Test func manualModesPickTheCurve() {
        #expect(ColourMapping.decide(ps5SDR, mode: .bt1886).layer == LayerColourSpace(primaries: .bt709, curve: .gamma24))
        #expect(ColourMapping.decide(ps5SDR, mode: .sRGB).layer == .sRGB)
        let legacy = ColourMapping.decide(ps5SDR, mode: .legacy709).layer
        #expect(legacy.makeColorSpace()?.name == CGColorSpace.itur_709)
        #expect(LayerColourSpace(primaries: .bt709, curve: .gamma24).makeColorSpace() != nil)
    }

    /// The default path must match the standard Rec.709 video-range coefficients exactly.
    @Test func bt709VideoRangeConstantsMatchTheOldShader() {
        let k = ColourMapping.standard.constants(tenBit: false)
        let close = { (a: Float, b: Double) in abs(Double(a) - b) < 1e-4 }
        #expect(close(k.r.z, 1.5748) && close(k.g.y, -0.1873) && close(k.g.z, -0.4681) && close(k.b.y, 1.8556))
        #expect(close(k.range.x, 255.0 / 219) && close(k.range.y, -16.0 / 219))
        #expect(close(k.range.z, 255.0 / 224) && close(k.range.w, -128.0 / 224))
        #expect(MemoryLayout<PresentColourConstants>.stride == 80)  // 5 x float4 in Present.metal
    }

    @Test func storedModeDefaultsToAutomatic() {
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        #expect(ColourMode.stored(defaults) == .automatic)
        defaults.set("bt1886", forKey: ColourMode.defaultsKey)
        #expect(ColourMode.stored(defaults) == .bt1886)
    }

    /// Shaders compile at runtime: catch Metal errors in Present.metal here, not at stream start.
    @Test func presentPipelinesBuild() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        _ = try PresentEncoder(context: RenderContext.shared())
    }
}
