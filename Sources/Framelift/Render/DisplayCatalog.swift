// SPDX-License-Identifier: AGPL-3.0-only
// Screens the stream can be shown on (built-in panel, TV over HDMI, ...).
import AppKit
import CoreGraphics

struct DisplayInfo: Identifiable, Hashable {
    /// CGDirectDisplayID
    var id: UInt32
    var name: String
    var refreshHz: Double
    var isBuiltIn: Bool
}

enum DisplayCatalog {
    static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Nominal refresh: the current display mode's rate, else NSScreen.maximumFramesPerSecond, else 60.
    static func refreshHz(of screen: NSScreen) -> Double {
        if let id = displayID(of: screen), let mode = CGDisplayCopyDisplayMode(id) {
            let r = mode.refreshRate
            if r > 1 { return r }
        }
        let m = screen.maximumFramesPerSecond
        return m > 0 ? Double(m) : 60
    }

    static func info(for screen: NSScreen) -> DisplayInfo? {
        guard let id = displayID(of: screen) else { return nil }
        return DisplayInfo(id: id, name: screen.localizedName, refreshHz: refreshHz(of: screen),
                           isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }

    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap(info(for:))
    }

    static func screen(for id: UInt32) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }
}

extension DisplayInfo {
    /// "LG TV — 60 Hz"
    var label: String {
        refreshHz > 0 ? "\(name) — \(Self.hzText(refreshHz)) Hz" : name
    }

    static func hzText(_ hz: Double) -> String {
        abs(hz - hz.rounded()) < 0.05 ? String(Int(hz.rounded())) : String(format: "%.2f", hz)
    }
}
