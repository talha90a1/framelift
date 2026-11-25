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
        #expect(wifi.bitrateKbps == 30_000)
        wifi.bitrateKbps = 20_000
        profiles.save(wifi, for: .wifi)
        #expect(profiles.load(.ethernet, preserving: wifi).bitrateKbps == 50_000)
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
        let wired = ConnectionProfile.ethernet.defaults(preserving: current)
        #expect(wired.streamFPS == 60 && !wired.fullscreen && wired.targetDisplayID == 42)
        #expect(!wired.keepStaticOverlays && !wired.blendFallback)
    }
}
