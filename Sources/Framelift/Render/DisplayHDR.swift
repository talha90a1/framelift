// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import QuartzCore

struct DisplayHDR: Equatable {
    let current: Double
    let potential: Double
    let reference: Double

    init(current: Double, potential: Double, reference: Double) {
        self.current = current
        self.potential = potential
        self.reference = reference
    }

    @MainActor init(screen: NSScreen?) {
        current = Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        potential = Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
        reference = Double(screen?.maximumReferenceExtendedDynamicRangeColorComponentValue ?? 0)
    }

    // Current headroom can be one until an HDR layer requests it.
    var available: Bool { potential.isFinite && potential > 1 }

    var summary: String {
        String(format: "HDR %@ EDR current=%.2f potential=%.2f reference=%.2f", available ? "available" : "unavailable", current, potential, reference)
    }

    func apply(to layer: CAMetalLayer, colour: LayerColourSpace) {
        let hdr = colour.isHDR && available
        let range: CALayer.DynamicRange = hdr ? .high : .standard
        let toneMap: CALayer.ToneMapMode = colour.isHDR ? .ifSupported : .never
        if layer.preferredDynamicRange != range { layer.preferredDynamicRange = range }
        if layer.wantsExtendedDynamicRangeContent != hdr { layer.wantsExtendedDynamicRangeContent = hdr }
        if layer.toneMapMode != toneMap { layer.toneMapMode = toneMap }
    }
}
