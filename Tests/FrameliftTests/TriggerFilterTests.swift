// SPDX-License-Identifier: GPL-3.0-only
// Framelift: ported from Veyra 17e54e24 (tests/remoteplay/TriggerFilterTests.cpp), same cases
// and values, for Sources/Framelift/Input/TriggerFilter.swift.
import Foundation
import Testing
@testable import Framelift

private func ms(_ v: Int) -> Double { Double(v) / 1000 }

/// The jitter scenario, driven through a model of Chiaki's history window: each value
/// change is one event, a packet repeats the newest 8, and a burst of packets is lost right after
/// L2 is released while R2 keeps jittering. True if the console ends up seeing L2 released.
private func consoleSeesL2Release(_ source: (UInt8, UInt8, Double) -> TriggerFilter.Values) -> Bool {
    var window: [(trigger: Int, value: UInt8)] = [] // newest 8 events, as in every packet
    var consoleL2: UInt8 = 0
    var prevL2: UInt8 = 0, prevR2: UInt8 = 0
    for tick in 0..<150 { // 4 ms controller cadence, 600 ms
        let now = ms(tick * 4)
        let l2: UInt8 = tick < 50 ? 200 : 0               // L2 released at 200 ms
        let r2 = UInt8(180 + (tick % 3) - 1)              // R2 held, jittering 179..181
        let out = source(l2, r2, now)
        var pushed = false
        func push(_ t: Int, _ v: UInt8) {
            window.append((t, v))
            if window.count > 8 { window.removeFirst() }
            pushed = true
        }
        if out.l2 != prevL2 { push(0, out.l2) }
        if out.r2 != prevR2 { push(1, out.r2) }
        prevL2 = out.l2; prevR2 = out.r2
        let lost = tick >= 50 && tick < 60                // 40 ms of lost packets
        // A packet goes out for each new event; with nothing new, the last packet is resent
        // (Chiaki tail resend at 20/50/100/200 ms).
        let tailResend = !pushed && [55, 62, 75, 100].contains(tick)
        if (pushed || tailResend) && !lost {
            for e in window where e.trigger == 0 { consoleL2 = e.value }
        }
    }
    return consoleL2 == 0
}

@Suite struct TriggerFilterTests {
    @Test func endsSnap() {
        var f = TriggerFilter()
        let v = f.apply(l2: 3, r2: 252, now: 0)
        #expect(v.l2 == 0 && v.r2 == 255)
    }

    @Test func belowStepHeldFullStepSent() {
        var f = TriggerFilter()
        _ = f.apply(l2: 100, r2: 0, now: 0)
        let a = f.apply(l2: 102, r2: 0, now: ms(4))
        let b = f.apply(l2: 104, r2: 0, now: ms(8))
        #expect(a.l2 == 100 && b.l2 == 104)
    }

    @Test func releaseAndFirstPressAtOnce() {
        var f = TriggerFilter()
        _ = f.apply(l2: 150, r2: 0, now: 0)
        var v = f.apply(l2: 0, r2: 0, now: ms(4))
        #expect(v.l2 == 0, "release is sent at once from any value")
        v = f.apply(l2: 40, r2: 0, now: ms(8))
        #expect(v.l2 == 40, "first press is sent at once")
    }

    @Test func otherTriggerHeldAfterRelease() {
        var f = TriggerFilter()
        _ = f.apply(l2: 200, r2: 120, now: 0)
        _ = f.apply(l2: 0, r2: 120, now: ms(4)) // L2 released
        let held = f.apply(l2: 0, r2: 160, now: ms(50))
        #expect(held.r2 == 120, "other trigger's in-between values held after a release")
        let full = f.apply(l2: 0, r2: 255, now: ms(60))
        #expect(full.r2 == 255, "other trigger reaching 255 still goes through during the hold")
        let after = f.apply(l2: 0, r2: 160, now: ms(200))
        #expect(after.r2 == 160, "held trigger catches up after the hold")
    }

    @Test func pressedTriggerNeverHeld() {
        var f = TriggerFilter()
        _ = f.apply(l2: 0, r2: 0, now: 0)
        _ = f.apply(l2: 30, r2: 0, now: ms(4))
        let ramp = f.apply(l2: 90, r2: 0, now: ms(8))
        #expect(ramp.l2 == 90)
    }

    @Test func resetStartsReleased() {
        var f = TriggerFilter()
        _ = f.apply(l2: 200, r2: 200, now: 0)
        f.reset()
        let v = f.apply(l2: 100, r2: 0, now: ms(4))
        #expect(v.l2 == 100)
    }

    @Test func historyModelSeesRelease() {
        #expect(!consoleSeesL2Release { l2, r2, _ in TriggerFilter.Values(l2: l2, r2: r2) },
                "model reproduces the stuck L2 without the filter")
        var f = TriggerFilter()
        #expect(consoleSeesL2Release { l2, r2, now in f.apply(l2: l2, r2: r2, now: now) },
                "with the filter the console sees the L2 release")
    }
}
