// SPDX-License-Identifier: AGPL-3.0-only
// Plain-text system report (app, macOS, Mac, displays, network, controller, settings) for events.log and exports.
import AppKit
import CoreGraphics
import Darwin
import Foundation
import SystemConfiguration

enum SystemReport {
    /// Main thread (NSScreen). The stream target is the chosen display, else the main window's screen.
    @MainActor
    static func make(settings: StreamSettings, controller: String?, controllerFeedback: String) -> String {
        let target =
            SettingsStore.resolvedDisplayID(settings.targetDisplayID, available: DisplayCatalog.displays().map(\.id))
            ?? (NSApp.mainWindow?.screen ?? NSScreen.main).flatMap(DisplayCatalog.displayID(of:))
        var lines = ["==== Framelift system report ===="]
        lines += environmentLines()
        lines.append("Displays:")
        lines += NSScreen.screens.map { "  " + displayLine($0, target: target) }
        lines.append("Mac internet: \(primaryInterface())")
        lines.append("Controller: \(controller ?? "none")")
        lines.append("Controller feedback: \(controllerFeedback) (setting: \(DualSenseFeedbackMode.stored().title))")
        lines.append("Settings:")
        lines += settingsLines(settings).map { "  " + $0 }
        lines.append("==== end of system report ====")
        return lines.joined(separator: "\n") + "\n"
    }

    static func environmentLines() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let app = version.map { "\($0) (\(build ?? "?"))" } ?? "development build (no bundle version)"
        let p = ProcessInfo.processInfo
        let thermal: String
        switch p.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return [
            "App: Framelift \(app)",
            "macOS: \(p.operatingSystemVersionString)",
            "Mac model: \(sysctlString("hw.model") ?? "unknown")",
            "Chip: \(sysctlString("machdep.cpu.brand_string") ?? "unknown")",
            String(format: "Memory: %.0f GB", Double(p.physicalMemory) / 1_073_741_824),
            "Thermal state: \(thermal)",
            "Low Power Mode: \(p.isLowPowerModeEnabled ? "on" : "off")",
        ]
    }

    /// Every user-facing setting; none of them is secret.
    static func settingsLines(_ s: StreamSettings, defaults: UserDefaults = .standard) -> [String] {
        [
            "stream \(s.width)x\(s.height)@\(s.streamFPS) bitrate=\(s.bitrateKbps)kbps codec=\(s.codec.label)",
            "display target=\(s.targetDisplayID.map(String.init) ?? "window's screen") fullscreen=\(s.fullscreen)",
            "frame generation keepWarm=\(s.keepLLFIWarm) keepStatic=\(s.keepStaticOverlays) blendFallback=\(s.blendFallback) sceneCutFallback=\(s.sceneCutFallback) buffers=\(DisplayBuffering.stored(defaults).drawableCount)",
            "touchpad=\(TouchpadMode.stored(defaults).rawValue) overlay=\(s.showOverlay) debugLogs=\(DebugLogs.stored(defaults))",
        ]
    }

    @MainActor
    static func displayLine(_ screen: NSScreen, target: UInt32?) -> String {
        guard let id = DisplayCatalog.displayID(of: screen) else { return screen.localizedName }
        var size = "\(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) px"
        if let mode = CGDisplayCopyDisplayMode(id) { size = "\(mode.pixelWidth)x\(mode.pixelHeight) px (\(mode.width)x\(mode.height) pt)" }
        let kind = CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external"
        let marker = id == target ? " [stream target]" : ""
        return "\(screen.localizedName) id=\(id) \(kind) \(size) refresh \(RefreshCapability.of(screen).summary)\(marker)"
    }

    /// How this Mac reaches the console: the local interface whose IPv4 subnet holds `host`.
    /// A bridge interface is Internet Sharing (or Thunderbolt Bridge), i.e. a cable to the Mac.
    static func consoleLink(host: String) -> String {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return "unknown" }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "unknown" }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard ifa.ifa_flags & UInt32(IFF_UP) != 0, let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard netmask != 0, ip & netmask == target.s_addr & netmask else { continue }
            let bsd = String(cString: ifa.ifa_name)
            if bsd.hasPrefix("bridge") { return "direct cable (Internet Sharing, \(bsd))" }
            return interfaceKind(bsd)
        }
        return "routed via \(primaryInterface())"
    }

    private static func interfaceKind(_ bsd: String) -> String {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let interface = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsd }) else { return bsd }
        let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
        if type == kSCNetworkInterfaceTypeIEEE80211 as String { return "Wi-Fi (\(bsd))" }
        if type == kSCNetworkInterfaceTypeEthernet as String { return "Ethernet (\(bsd))" }
        return "\(type ?? "unknown") (\(bsd))"
    }

    /// Kind of the interface carrying the default IPv4 route ("Wi-Fi (en0)"). Never the SSID or BSSID.
    static func primaryInterface() -> String {
        guard let store = SCDynamicStoreCreate(nil, "Framelift" as CFString, nil, nil),
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let bsd = global["PrimaryInterface"] as? String
        else { return "no default route" }
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let interface = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == bsd }) else { return bsd }
        let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
        let kind: String
        if type == kSCNetworkInterfaceTypeIEEE80211 as String {
            kind = "Wi-Fi"
        } else if type == kSCNetworkInterfaceTypeEthernet as String {
            kind = "Ethernet"
        } else {
            kind = type ?? "unknown"
        }
        let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? kind
        return name == kind ? "\(kind) (\(bsd))" : "\(kind): \(name) (\(bsd))"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
