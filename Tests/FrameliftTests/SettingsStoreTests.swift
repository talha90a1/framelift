// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct SettingsStoreTests {
    /// A private defaults domain per test so nothing touches the real app's preferences.
    private func makeStore() -> (SettingsStore, UserDefaults, String) {
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    @Test func defaultsWhenNothingSaved() {
        let (store, _, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        let settings = store.load()
        #expect(settings == StreamSettings())
        #expect(StreamPreset(settings: settings) == .p1080fps30)
    }

    @Test func roundTrip() {
        let (store, _, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        var settings = StreamSettings()
        StreamPreset.p720fps60.apply(to: &settings)
        settings.bitrateKbps = 9000
        settings.codec = .h264
        settings.targetDisplayID = 4_128_835
        settings.fullscreen = false
        settings.showOverlay = true
        settings.keepLLFIWarm = false
        settings.keepStaticOverlays = true
        settings.blendFallback = true
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func corruptDataFallsBackToDefaults() {
        let (store, defaults, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        #expect(store.load() == StreamSettings())
    }

    @Test func outOfRangeValuesAreSanitized() throws {
        let (store, defaults, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        var settings = StreamSettings()
        settings.width = 3840
        settings.height = 2160
        settings.bitrateKbps = 999_999
        defaults.set(try JSONEncoder().encode(settings), forKey: SettingsStore.key)
        let loaded = store.load()
        #expect(StreamPreset(settings: loaded) == .p1080fps30)
        #expect(loaded.bitrateKbps == StreamSettingsLimits.bitrateRangeKbps.upperBound)
    }

    @Test func sharpnessIsClampedAndNaNResets() {
        var settings = StreamSettings()
        settings.sharpness = 7
        #expect(SettingsStore.sanitized(settings).sharpness == StreamSettingsLimits.sharpnessRange.upperBound)
        settings.sharpness = -1
        #expect(SettingsStore.sanitized(settings).sharpness == 0)
        settings.sharpness = .nan
        #expect(SettingsStore.sanitized(settings).sharpness == StreamSettingsLimits.defaultSharpness)
        settings.sharpness = 1.2
        #expect(SettingsStore.sanitized(settings).sharpness == 1.2)
    }

    @Test func bitrateUpTo100MbpsIsKept() {
        var settings = StreamSettings()
        settings.bitrateKbps = 100_000
        #expect(SettingsStore.sanitized(settings).bitrateKbps == 100_000)
    }

    @Test func hdrAndUpscalerAreKept() {
        var settings = StreamSettings()
        settings.codec = .hevcHDR
        settings.upscaler = .metalFX
        let sanitized = SettingsStore.sanitized(settings)
        #expect(sanitized.codec == .hevcHDR && sanitized.upscaler == .metalFX)
    }

    @Test func unknownUpscalerFallsBackToDefault() throws {
        let data = Data(#"{"upscaler":"lanczos","sharpness":0.8}"#.utf8)
        let decoded = try JSONDecoder().decode(StreamSettings.self, from: data)
        #expect(decoded.upscaler == .sharp && decoded.sharpness == 0.8)
    }

    @Test func unpluggedDisplayResolvesToMainWindowScreen() {
        #expect(SettingsStore.resolvedDisplayID(7, available: [1, 7]) == 7)
        #expect(SettingsStore.resolvedDisplayID(9, available: [1, 7]) == nil)
        #expect(SettingsStore.resolvedDisplayID(nil, available: [1]) == nil)
    }

    /// Settings saved before a field existed keep their values; the missing fields take their defaults.
    @Test func missingKeysTakeDefaults() throws {
        let (store, defaults, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        let partial = #"{"width":1280,"height":720,"streamFPS":60,"bitrateKbps":9000,"codec":0,"fullscreen":false,"sceneCutFallback":true}"#
        defaults.set(Data(partial.utf8), forKey: SettingsStore.key)
        let loaded = store.load()
        #expect(StreamPreset(settings: loaded) == .p720fps60)
        #expect(loaded.bitrateKbps == 9000 && loaded.codec == .h264 && !loaded.fullscreen)
        #expect(loaded.showOverlay == false)
        #expect(loaded.keepLLFIWarm && !loaded.keepStaticOverlays && !loaded.blendFallback)
        #expect(loaded.sharpness == StreamSettingsLimits.defaultSharpness)
    }

    @Test func resetsOldMotionDefaultsOnce() throws {
        let (store, defaults, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        defaults.set(Data(#"{"bitrateKbps":50000,"keepStaticOverlays":true,"blendFallback":true}"#.utf8), forKey: SettingsStore.key)
        var migrated = store.load()
        #expect(migrated.bitrateKbps == 50_000 && !migrated.keepStaticOverlays && !migrated.blendFallback)
        migrated.keepStaticOverlays = true
        migrated.blendFallback = true
        store.save(migrated)
        #expect(store.load() == migrated)
    }

    @Test func pairedConsoleWithPartialSettingsDecodes() throws {
        let json =
            #"[{"id":"aa","nickname":"PS5","host":"192.168.1.2","lastSettings":{"width":1920,"height":1080,"streamFPS":30,"bitrateKbps":50000,"codec":1,"fullscreen":true,"sceneCutFallback":true,"showOverlay":false}}]"#
        let consoles = try JSONDecoder().decode([PairedConsole].self, from: Data(json.utf8))
        #expect(consoles.first?.lastSettings?.bitrateKbps == 50000)
    }

    @Test func debugLogsUseDefaultAndHonorSavedChoice() {
        let (_, defaults, suite) = makeStore()
        defer { removeTestDefaults(suite) }
        #expect(DebugLogs.stored(defaults) == DebugLogs.enabledByDefault)
        defaults.set(false, forKey: DebugLogs.defaultsKey)
        #expect(DebugLogs.stored(defaults) == false)
        defaults.set(true, forKey: DebugLogs.defaultsKey)
        #expect(DebugLogs.stored(defaults))
    }
}

struct DefaultSettingsTests {
    /// Defaults for a new install.
    @Test func newInstallDefaults() {
        let s = StreamSettings()
        #expect(s.width == 1920 && s.height == 1080 && s.streamFPS == 30)
        #expect(s.bitrateKbps == 30000)
        #expect(s.codec == .hevc)
        #expect(s.showOverlay == false)
        #expect(s.keepLLFIWarm && !s.keepStaticOverlays && !s.blendFallback)
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        #expect(DisplayBuffering.stored(defaults) == .triple)
        #expect(DisplayBuffering.triple.drawableCount == 3)
    }

    /// Debug logs off: a stream start writes nothing to ~/Library/Logs/Framelift.
    @Test func diagnosticsOffByDefault() {
        let d = Diagnostics()
        #expect(d.enabled == false)
        d.beginSession(label: "test")
        d.event("not written")
        #expect(d.directory == nil)
    }
}
