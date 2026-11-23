// SPDX-License-Identifier: AGPL-3.0-only
// Screen refresh capability (fixed or variable range), for the event log and display-link rebuilds.
import AppKit
import CoreGraphics
import Foundation

/// What the screen reports about its refresh.
struct RefreshCapability: Equatable, Sendable {
    /// Fastest refresh period (s), e.g. 1/120.
    var minInterval: Double
    /// Slowest refresh period (s), e.g. 1/48 on a 48-120 Hz panel; equal to minInterval when fixed.
    var maxInterval: Double
    /// Granularity of refresh changes (s); 0 = continuous.
    var granularity: Double
    /// The current display mode's nominal rate (CGDisplayMode; 0 when it reports none).
    var modeHz: Double

    /// The panel is in a variable-refresh mode now.
    var isVariable: Bool { minInterval > 0 && maxInterval > minInterval * 1.05 + 0.0002 }
    var maxHz: Double { minInterval > 0 ? 1 / minInterval : 0 }
    var minHz: Double { maxInterval > 0 ? 1 / maxInterval : 0 }

    var summary: String {
        let raw = String(format: "minInterval=%.5f maxInterval=%.5f granularity=%.5f mode=%.2f Hz", minInterval, maxInterval, granularity, modeHz)
        return isVariable
            ? String(format: "variable %.0f-%.0f Hz (%@)", minHz, maxHz, raw)
            : String(format: "fixed %.2f Hz (%@)", maxHz, raw)
    }

    static func of(_ screen: NSScreen) -> RefreshCapability {
        var modeHz = 0.0
        if let id = DisplayCatalog.displayID(of: screen), let mode = CGDisplayCopyDisplayMode(id) { modeHz = mode.refreshRate }
        return RefreshCapability(minInterval: screen.minimumRefreshInterval, maxInterval: screen.maximumRefreshInterval,
                                 granularity: screen.displayUpdateGranularity, modeHz: modeHz)
    }
}
