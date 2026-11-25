// SPDX-License-Identifier: AGPL-3.0-only
// StreamSettings persistence (UserDefaults, JSON) and the PS5 stream presets. Pure Foundation.
import Foundation

/// The four presets the PS5 offers for Remote Play.
enum StreamPreset: String, CaseIterable, Identifiable {
    case p720fps30, p720fps60, p1080fps30, p1080fps60

    var id: String { rawValue }
    var width: UInt32 { is1080 ? 1920 : 1280 }
    var height: UInt32 { is1080 ? 1080 : 720 }
    var fps: UInt32 { self == .p720fps30 || self == .p1080fps30 ? 30 : 60 }
    var title: String { "\(height)p · \(fps) fps" }

    private var is1080: Bool { self == .p1080fps30 || self == .p1080fps60 }

    init?(settings: StreamSettings) {
        guard
            let match = Self.allCases.first(where: {
                $0.width == settings.width && $0.height == settings.height && $0.fps == settings.streamFPS
            })
        else { return nil }
        self = match
    }

    func apply(to settings: inout StreamSettings) {
        settings.width = width
        settings.height = height
        settings.streamFPS = fps
    }
}

enum StreamSettingsLimits {
    static let bitrateRangeKbps: ClosedRange<UInt32> = 2000...100_000
    static let sharpnessRange: ClosedRange<Double> = 0...1.5
    static let defaultSharpness = 0.5
}

/// Loads and saves `StreamSettings` as JSON in UserDefaults. Unknown or corrupt data falls back to defaults.
struct SettingsStore {
    static let key = "framelift.streamSettings.v1"
    private static let motionDefaultsKey = "framelift.motionDefaults.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StreamSettings {
        guard let data = defaults.data(forKey: Self.key),
            var decoded = try? JSONDecoder().decode(StreamSettings.self, from: data)
        else { return StreamSettings() }
        if !defaults.bool(forKey: Self.motionDefaultsKey) {
            decoded.keepStaticOverlays = false
            decoded.blendFallback = false
            save(decoded)
        }
        return Self.sanitized(decoded)
    }

    func save(_ settings: StreamSettings) {
        guard let data = try? JSONEncoder().encode(Self.sanitized(settings)) else { return }
        defaults.set(data, forKey: Self.key)
        defaults.set(true, forKey: Self.motionDefaultsKey)
    }

    /// Clamps stored values to what the app offers: a PS5 preset, a bitrate and a sharpness in range.
    static func sanitized(_ settings: StreamSettings) -> StreamSettings {
        var result = settings
        if StreamPreset(settings: result) == nil { StreamPreset.p1080fps30.apply(to: &result) }
        let range = StreamSettingsLimits.bitrateRangeKbps
        result.bitrateKbps = min(max(result.bitrateKbps, range.lowerBound), range.upperBound)
        let sharp = StreamSettingsLimits.sharpnessRange
        result.sharpness =
            result.sharpness.isFinite
            ? min(max(result.sharpness, sharp.lowerBound), sharp.upperBound) : StreamSettingsLimits.defaultSharpness
        result.audioOffsetMs = result.audioOffsetMs.isFinite ? min(250, max(-250, result.audioOffsetMs)) : 0
        return result
    }

    /// The target display if it is still connected (a TV may have been unplugged), else nil = main window's screen.
    static func resolvedDisplayID(_ requested: UInt32?, available: [UInt32]) -> UInt32? {
        guard let requested, available.contains(requested) else { return nil }
        return requested
    }
}
