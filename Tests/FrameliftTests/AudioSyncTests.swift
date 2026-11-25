// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import Framelift

struct AudioSyncTests {
    @Test func startupBacklogDoesNotBecomeNormalDelay() {
        var sync = AudioSync()
        for delay in [400.0, 200, 49, 50, 51, 49] {
            sync.observe(videoDelayMs: delay, outputLatencyMs: 10, offsetMs: 0)
        }
        #expect(!sync.settled)
        sync.observe(videoDelayMs: 50, outputLatencyMs: 10, offsetMs: 0)
        #expect(sync.settled && sync.targetMs == 40)
    }

    @Test func accountsForDeviceDelayAndManualOffset() {
        var sync = AudioSync()
        for _ in 0..<5 { sync.observe(videoDelayMs: 60, outputLatencyMs: 20, offsetMs: 15) }
        #expect(sync.targetMs == 55)
        sync.observe(videoDelayMs: .nan, outputLatencyMs: 0, offsetMs: 0)
        #expect(sync.targetMs == 55)
    }

    @Test func keepsAJitterBufferWhenVideoIsFastAndGrowsAfterUnderruns() {
        var sync = AudioSync()
        for _ in 0..<5 { sync.observe(videoDelayMs: 15, outputLatencyMs: 5, offsetMs: 0) }
        #expect(sync.targetMs == 40)
        sync.noteUnderrun()
        for _ in 0..<20 { sync.observe(videoDelayMs: 15, outputLatencyMs: 5, offsetMs: 0) }
        #expect(sync.targetMs >= 50)
        for _ in 0..<50 { sync.noteUnderrun() }
        #expect(sync.minimumTargetMs == 120)
    }

    @Test func driftCorrectionIsSmallAndFollowsBufferPressure() {
        #expect(AudioSync.driftStep(available: 1920, target: 1920, rate: 48000) == 1)
        #expect(AudioSync.driftStep(available: 2400, target: 1920, rate: 48000) > 1)
        #expect(AudioSync.driftStep(available: 1440, target: 1920, rate: 48000) < 1)
        #expect(AudioSync.driftStep(available: 32000, target: 1920, rate: 48000) <= 1.003)
    }
}
