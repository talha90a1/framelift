// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct AudioSync {
    static let maximumJitterMs: Double = 120
    private var delays: [Double] = []
    private(set) var targetMs: Double = 40
    private(set) var settled = false
    private(set) var minimumTargetMs: Double = 40

    mutating func noteUnderrun(deliveryOutage: Bool = false) {
        guard !deliveryOutage else { return }
        minimumTargetMs = min(Self.maximumJitterMs, minimumTargetMs + 10)
        targetMs = max(targetMs, minimumTargetMs)
    }

    mutating func observe(videoDelayMs: Double, outputLatencyMs: Double, offsetMs: Double) {
        guard videoDelayMs.isFinite, videoDelayMs >= 0, videoDelayMs < 500 else { return }
        delays.append(videoDelayMs)
        if delays.count > 5 { delays.removeFirst() }
        let sorted = delays.sorted()
        guard sorted.count == 5, sorted.last! - sorted.first! <= 20 else { return }
        let requested = min(350, max(minimumTargetMs, sorted[2] - max(0, outputLatencyMs) + offsetMs))
        targetMs = settled ? targetMs + (requested - targetMs) * 0.05 : requested
        settled = true
    }

    static func driftStep(available: Int, target: Int, rate: Double) -> Double {
        1 + min(0.003, max(-0.003, Double(available - target) / rate * 0.02))
    }
}
