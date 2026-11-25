// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum ConnectionProfile: String, Codable, CaseIterable, Identifiable {
    case automatic, wifi, ethernet, internet, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic (recommended)"
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .internet: "Away from home"
        case .custom: "Custom"
        }
    }

    var recommendedBitrate: UInt32 {
        switch self {
        case .ethernet: 100_000
        case .internet: 15_000
        default: 15_000
        }
    }

    static func detected(consoleLink: String, remote: Bool = false) -> Self {
        if remote { return .internet }
        if consoleLink.hasPrefix("direct cable") || consoleLink.hasPrefix("Ethernet") { return .ethernet }
        return .wifi
    }

    func defaults(preserving settings: StreamSettings = StreamSettings()) -> StreamSettings {
        var result = settings
        result.bitrateKbps = recommendedBitrate
        result.codec = .hevc
        result.protectSubtitles = true
        result.keepStaticOverlays = false
        result.blendFallback = false
        return result
    }
}

struct ConnectionProfiles {
    private static let choiceKey = "framelift.connectionProfile.v1"
    private static let profilesKey = "framelift.connectionProfiles.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var selection: ConnectionProfile {
        get { defaults.string(forKey: Self.choiceKey).flatMap(ConnectionProfile.init(rawValue:)) ?? .automatic }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.choiceKey) }
    }

    func load(_ profile: ConnectionProfile, preserving current: StreamSettings) -> StreamSettings {
        if let saved = all()[profile.rawValue] {
            var result = SettingsStore.sanitized(saved)
            result.showOverlay = current.showOverlay
            return result
        }
        return profile == .custom ? current : profile.defaults(preserving: current)
    }

    func save(_ settings: StreamSettings, for profile: ConnectionProfile) {
        guard profile != .automatic else { return }
        var profiles = all()
        profiles[profile.rawValue] = SettingsStore.sanitized(settings)
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
    }

    func preservePreviousSettings(_ settings: StreamSettings) {
        guard all()[ConnectionProfile.custom.rawValue] == nil else { return }
        save(settings, for: .custom)
    }

    private func all() -> [String: StreamSettings] {
        guard let data = defaults.data(forKey: Self.profilesKey),
              let profiles = try? JSONDecoder().decode([String: StreamSettings].self, from: data) else { return [:] }
        return profiles
    }
}
