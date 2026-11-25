// SPDX-License-Identifier: AGPL-3.0-only
import Metal
import QuartzCore
import Testing
@testable import Framelift

struct DisplayHDRTests {
    @Test @MainActor func displayChangesToneMapHDRWithoutChangingItsEncoding() {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgr10a2Unorm
        for curve in [LayerCurve.pq, .hlg] {
            let colour = LayerColourSpace(primaries: .bt2020, curve: curve)
            layer.colorspace = colour.makeColorSpace()
            let space = layer.colorspace?.name
            for potential in [4.18, 1, 4.18] {
                DisplayHDR(current: 1, potential: potential, reference: 0).apply(to: layer, colour: colour)
                #expect(layer.wantsExtendedDynamicRangeContent == (potential > 1))
                #expect(layer.preferredDynamicRange == (potential > 1 ? .high : .standard))
                #expect(layer.toneMapMode == .ifSupported)
                #expect(layer.pixelFormat == .bgr10a2Unorm)
                #expect(layer.colorspace?.name == space)
            }
        }
    }

    @Test @MainActor func sdrAfterHDRDoesNotKeepTheHDRToneMap() {
        let layer = CAMetalLayer()
        let display = DisplayHDR(current: 1.2, potential: 4.18, reference: 0)
        display.apply(to: layer, colour: LayerColourSpace(primaries: .bt2020, curve: .pq))
        display.apply(to: layer, colour: .sRGB)
        #expect(!layer.wantsExtendedDynamicRangeContent)
        #expect(layer.preferredDynamicRange == .standard)
        #expect(layer.toneMapMode == .never)
    }

    @Test func idleDisplayUsesPotentialHeadroomAndInvalidValuesStaySDR() {
        #expect(DisplayHDR(current: 1, potential: 4.18, reference: 0).available)
        for potential in [0, 1, Double.nan, .infinity] {
            #expect(!DisplayHDR(current: 1, potential: potential, reference: 0).available)
        }
    }
}
