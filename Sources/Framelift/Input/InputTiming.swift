// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct InputTiming {
    private var events = PercentileWindow(capacity: 256)
    private var sends = PercentileWindow(capacity: 256)
    private var ticks = PercentileWindow(capacity: 256)
    private var bodies = PercentileWindow(capacity: 256)
    private var lastTick: Double?

    mutating func event(latency: Double) {
        guard latency.isFinite, latency >= 0, latency < 5 else { return }
        events.add(latency * 1000)
    }

    mutating func body(milliseconds: Double) { bodies.add(milliseconds) }

    mutating func sent(milliseconds: Double) { sends.add(milliseconds) }

    mutating func tick(at now: Double) {
        if let lastTick { ticks.add((now - lastTick) * 1000) }
        lastTick = now
    }

    var summary: String {
        let input = events.count == 0 ? "native input latency unavailable" : String(format: "native input latency lower-bound n=%d p50/p95/max=%.2f/%.2f/%.2fms", events.count, events.percentile(0.5), events.percentile(0.95), events.percentile(1))
        return String(format: "controller %@ send-call p95/max=%.2f/%.2fms timer-gap p95/max=%.2f/%.2fms timer-body p95/max=%.2f/%.2fms", input,
               sends.percentile(0.95), sends.percentile(1), ticks.percentile(0.95), ticks.percentile(1), bodies.percentile(0.95), bodies.percentile(1))
    }
}
