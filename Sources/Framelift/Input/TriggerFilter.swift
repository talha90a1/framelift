// SPDX-License-Identifier: GPL-3.0-only
// Framelift: ported from Veyra (Likely7/Veyra-NRVideo, include/veyra/remoteplay/TriggerFilter.h).
// L2/R2 jitter filter: Chiaki's feedback history repeats only the newest 8 events, so jitter on one
// trigger can push the other's release out of the window; after a release the other trigger's
// in-between values are held for `edgeHold` so the release stays the newest event.
struct TriggerFilter {
    static let deadzone = 6
    static let step = 4
    static let edgeHold: Double = 0.120 // seconds

    struct Values: Equatable { var l2: UInt8 = 0, r2: UInt8 = 0 }

    private var sent: [Int] = [0, 0]
    private var holdUntil: [Double] = [-.infinity, -.infinity]

    /// `now` in seconds on any monotonic clock (InputManager: `HostClock.seconds(HostClock.now())`).
    mutating func apply(l2: UInt8, r2: UInt8, now: Double) -> Values {
        let raw = [Self.snap(Int(l2)), Self.snap(Int(r2))]
        for i in 0..<2 {
            let other = 1 - i
            let v = raw[i]
            if v == sent[i] { continue }
            if v == 0 || v == 255 || sent[i] == 0 {
                if v == 0 && sent[i] != 0 { holdUntil[other] = now + Self.edgeHold }
                sent[i] = v
                continue
            }
            if now < holdUntil[i] { continue }
            if abs(v - sent[i]) >= Self.step { sent[i] = v }
        }
        return Values(l2: UInt8(sent[0]), r2: UInt8(sent[1]))
    }

    /// Controller change or stop: the next read starts from released triggers.
    mutating func reset() { self = TriggerFilter() }

    private static func snap(_ v: Int) -> Int {
        if v <= deadzone { return 0 }
        if v >= 255 - deadzone { return 255 }
        return v
    }
}
