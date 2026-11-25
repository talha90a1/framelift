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

    @Test func recordedWiFiOutageDoesNotRatchetTheFloor() {
        var sync = AudioSync()
        for _ in 0..<5 { sync.observe(videoDelayMs: 70, outputLatencyMs: 0, offsetMs: 0) }
        // Counter snapshots at 22, 42, 43, 44, 45 and 46 seconds in the 15:16:51 Wi-Fi run.
        // The last three observations follow 146 ms and 541 ms delivery gaps.
        let observations: [(underruns: Int, recovery: Bool)] = [(1, false), (2, false), (3, false),
                                                               (5, true), (7, true), (8, true)]
        var previous = 0
        for observation in observations {
            for _ in previous..<observation.underruns { sync.noteUnderrun(deliveryOutage: observation.recovery) }
            previous = observation.underruns
            sync.observe(videoDelayMs: 70, outputLatencyMs: 0, offsetMs: 0)
        }
        #expect(sync.minimumTargetMs == 70)
        #expect(sync.targetMs == 70)
    }

    @Test func deliveryRecoveryUsesRecentAndActiveGapsAndResets() {
        let ring = AudioRing(capacityFrames: 4096)
        func ticks(_ seconds: Double) -> UInt64 { HostClock.ticks(seconds: seconds) }
        ring.noteEnqueue(at: ticks(10))
        #expect(!ring.deliveryIsRecovering(at: ticks(10.11)))
        #expect(ring.deliveryIsRecovering(at: ticks(10.13)))
        ring.noteEnqueue(at: ticks(10.5411))
        for index in 1...110 {
            ring.noteEnqueue(at: ticks(10.5411 + Double(index) * 0.01))
        }
        #expect(!ring.deliveryIsRecovering(at: ticks(11.642)))
        #expect(HostClock.seconds(ring.enqueueGapMax.load(ordering: .relaxed)) > 0.54)
        ring.noteEnqueue(at: ticks(12.1832))
        ring.noteEnqueue(at: ticks(12.1932))
        #expect(ring.deliveryIsRecovering(at: ticks(12.2)))
        ring.resetDeliveryClock()
        #expect(!ring.deliveryIsRecovering(at: ticks(12.2)))
        ring.noteEnqueue(at: ticks(20))
        #expect(!ring.deliveryIsRecovering(at: ticks(20.01)))
    }

    @Test func driftCorrectionIsSmallAndFollowsBufferPressure() {
        #expect(AudioSync.driftStep(available: 1920, target: 1920, rate: 48000) == 1)
        #expect(AudioSync.driftStep(available: 2400, target: 1920, rate: 48000) > 1)
        #expect(AudioSync.driftStep(available: 1440, target: 1920, rate: 48000) < 1)
        #expect(AudioSync.driftStep(available: 32000, target: 1920, rate: 48000) <= 1.003)
    }
}
