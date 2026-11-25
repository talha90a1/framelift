// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct ConnectionProfilesTests {
    @Test func followsConsoleRouteRatherThanInternetInterface() {
        #expect(ConnectionProfile.detected(consoleLink: "direct cable (Internet Sharing, bridge100)") == .ethernet)
        #expect(ConnectionProfile.detected(consoleLink: "Ethernet (en5)") == .ethernet)
        #expect(ConnectionProfile.detected(consoleLink: "Wi-Fi (en0)") == .wifi)
        #expect(ConnectionProfile.detected(consoleLink: "unknown") == .wifi)
        #expect(ConnectionProfile.detected(consoleLink: "Ethernet (en5)", remote: true) == .internet)
    }

    @Test func editsAreKeptSeparatelyAndPreviousSettingsAreRecoverable() {
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let profiles = ConnectionProfiles(defaults: defaults)
        var old = StreamSettings()
        old.bitrateKbps = 100_000
        profiles.preservePreviousSettings(old)
        var wifi = profiles.load(.wifi, preserving: old)
        #expect(wifi.bitrateKbps == 15_000)
        wifi.bitrateKbps = 20_000
        profiles.save(wifi, for: .wifi)
        #expect(profiles.load(.ethernet, preserving: wifi).bitrateKbps == 100_000)
        #expect(profiles.load(.wifi, preserving: old).bitrateKbps == 20_000)
        #expect(profiles.load(.custom, preserving: wifi).bitrateKbps == 100_000)
        #expect(profiles.selection == .automatic)
        profiles.selection = .ethernet
        #expect(ConnectionProfiles(defaults: defaults).selection == .ethernet)
    }

    @Test func recommendationsPreserveGameAndDisplayChoices() {
        var current = StreamSettings()
        current.streamFPS = 60
        current.fullscreen = false
        current.targetDisplayID = 42
        current.codec = .h264
        let wired = ConnectionProfile.ethernet.defaults(preserving: current)
        #expect(wired.streamFPS == 60 && !wired.fullscreen && wired.targetDisplayID == 42)
        #expect(!wired.keepStaticOverlays && !wired.blendFallback)
        #expect(wired.codec == .hevc)
    }

    @Test func legacyHDRProfileUsesHEVCWithoutLosingSavedChoices() {
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let json = #"{"wifi":{"width":1280,"height":720,"streamFPS":30,"bitrateKbps":22000,"codec":2,"targetDisplayID":42,"fullscreen":false,"sharpness":0.8},"ethernet":{"bitrateKbps":85000,"codec":1}}"#
        defaults.set(Data(json.utf8), forKey: "framelift.connectionProfiles.v1")
        let profiles = ConnectionProfiles(defaults: defaults)
        let wifi = profiles.load(.wifi, preserving: StreamSettings())
        #expect(wifi.codec == .hevc && StreamPreset(settings: wifi) == .p720fps30)
        #expect(wifi.bitrateKbps == 22_000 && wifi.targetDisplayID == 42)
        #expect(!wifi.fullscreen && wifi.sharpness == 0.8)
        #expect(profiles.load(.ethernet, preserving: wifi).bitrateKbps == 85_000)
    }

    @Test func changingNetworkProfilesDoesNotChangeOverlayVisibility() {
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let profiles = ConnectionProfiles(defaults: defaults)
        var saved = StreamSettings()
        saved.showOverlay = true
        profiles.save(saved, for: .ethernet)
        var current = StreamSettings()
        #expect(!profiles.load(.ethernet, preserving: current).showOverlay)
        saved.showOverlay = false
        profiles.save(saved, for: .wifi)
        current.showOverlay = true
        #expect(profiles.load(.wifi, preserving: current).showOverlay)
    }
}
