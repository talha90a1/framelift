// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

/// A small deterministic driver making the same tick / wait / late-latch / presented calls as
/// PresentationEngine. Glass time is the vsync target plus a present backlog: a stall adds one
/// refresh, a vsync with no commit drains one.
/// `tvLag`: the glass is one refresh after that (TV / compositor latency no drain removes), except
/// the first present after an empty vsync and the first `onTimePresents`, which land on target.
/// `generated`: generated frames per pair (1: 60 fps output, 3: 120 fps output). `tickEvery`: the
/// display link calls back every n refreshes but reports the panel's refresh (a pinned link).
private struct PacerRun {
    var a2p: [(t: Double, ms: Double)] = []  // arrival -> glass of real frames after 1 s
    var realIntervals: [Int] = []  // in panel refreshes
    var counters = PacerCounters()
    var rescues = 0
    var earlierSteps: [Double] = []  // vsync times of phase steps
    var laterSteps: [Double] = []
    var drains: [Double] = []
    var holds: [Int] = []  // refreshes each committed image stayed up (after 1 s)
    var generatedPerPair: [Int] = []  // generated images shown before each real frame (after 1 s)

    /// How many images were held each number of refreshes (for failure messages).
    var holdCounts: [Int: Int] { Dictionary(grouping: holds) { $0 }.mapValues(\.count) }

    /// Later steps within `window` s after an earlier step (earlier/later flapping).
    func flaps(within window: Double = 10) -> Int {
        laterSteps.filter { l in earlierSteps.contains { l > $0 && l - $0 < window } }.count
    }

    func mean(_ from: Double, _ to: Double) -> Double {
        let v = a2p.filter { $0.t >= from && $0.t < to }.map(\.ms)
        return v.reduce(0, +) / Double(max(1, v.count))
    }

    /// Least-squares slope of a2p over time (ms per s).
    var slope: Double {
        let n = Double(a2p.count)
        let mt = a2p.map(\.t).reduce(0, +) / n, ma = a2p.map(\.ms).reduce(0, +) / n
        let cov = a2p.reduce(0) { $0 + ($1.t - mt) * ($1.ms - ma) }
        let varT = a2p.reduce(0) { $0 + ($1.t - mt) * ($1.t - mt) }
        return cov / varT
    }
}

private func simulatePacer(
    fps: Double, hz: Double = 60, seconds: Double, generated: Int = 1, tickEvery: Int = 1,
    interpMs: (Double) -> Double, stallAt: Double? = nil, lagStepAt: Double? = nil,
    tvLag: Bool = false, onTimePresents: Int = 0, seed: UInt64 = 7
) -> PacerRun {
    var rng = seed
    func uniform() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
    func gauss() -> Double { let u = max(1e-12, uniform()), v = uniform(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) }

    struct Frame { var id: UInt64; var arrival: Double; var decoded: Double; var midDone: Double; var anchor = 0.0 }
    var frames: [Frame] = []
    var t = 0.1
    while t < seconds + 0.2 {
        let arrival = t + gauss() * 0.0015
        let decoded = arrival + 0.0025
        let interp = max(0.003, (interpMs(t) + gauss()) / 1000)
        frames.append(Frame(id: UInt64(frames.count + 1), arrival: arrival, decoded: decoded, midDone: decoded + interp))
        t += 1 / fps
    }

    let pacer = FramePacer()
    pacer.nominalInterval = 1 / fps.rounded()
    pacer.reset()
    let r = 1 / hz * Double(tickEvery), lead = pacer.commitLead, grid0 = 0.0037
    var run = PacerRun()
    var next = 0
    var pending: [Frame] = []
    var held: Double?
    var committed = false
    var backlog = 0, stalled = false
    var inFlight: [(glass: Double, target: Double)] = []
    var lastRealGlass: Double?
    var previousEmpty = false, presents = 0
    var lastImageGlass: Double?
    var generatedSinceReal = 0
    func noteImage(_ glass: Double) {
        if glass > 1, let l = lastImageGlass { run.holds.append(Int(((glass - l) * hz).rounded())) }
        lastImageGlass = glass
    }
    // A lasting one-refresh lag that no drain removes (display / compositor change).
    func glassTime(_ target: Double) -> Double {
        presents += 1
        let tv = tvLag && !previousEmpty && presents > onTimePresents ? r : 0.0003 * (tvLag ? 1 : 0)
        return target + Double(backlog) * r + (lagStepAt.map { target >= $0 ? r : 0 } ?? 0) + tv
    }

    func record(_ d: PacerDecision, _ target: Double) {
        switch d {
        case let .real(id, _):
            if let s = stallAt, !stalled, target >= s { backlog += 1; stalled = true }
            let glass = glassTime(target)
            committed = true
            inFlight.append((glass, target))
            if glass > 1, let f = frames.first(where: { $0.id == id }) {
                run.a2p.append((glass, (glass - f.arrival) * 1000))
                if let l = lastRealGlass { run.realIntervals.append(Int(((glass - l) * hz).rounded())) }
            }
            lastRealGlass = glass
            noteImage(glass)
            if glass > 1 { run.generatedPerPair.append(generatedSinceReal) }
            generatedSinceReal = 0
        case .generated:
            committed = true
            let glass = glassTime(target)
            inFlight.append((glass, target))
            noteImage(glass)
            generatedSinceReal += 1
        case .hold:
            held = target
        case .waitForMid:
            break
        }
    }

    func decide(_ d: PacerDecision, _ target: Double) {
        guard case let .waitForMid(id, _, deadline) = d else { return record(d, target) }
        let done = pending.first { $0.id == id }?.midDone ?? -1
        if done < 0 {
            record(pacer.resolveWait(id: id, target: target), target)
        } else if done <= deadline {
            deliver(upTo: done, latch: nil)
            record(pacer.resolveWait(id: id, target: target), target)
        } else {
            deliver(upTo: deadline, latch: nil)
            if pending.contains(where: { $0.id == id }) { run.rescues += 1; pacer.midFinished(id: id, ok: true) }
            record(pacer.expireWait(id: id, target: target), target)
        }
    }

    func deliver(upTo time: Double, latch: Double?) {
        while true {
            let nextArrival = next < frames.count ? frames[next].decoded : .infinity
            let nextMid = pending.map(\.midDone).min() ?? .infinity
            let at = min(nextArrival, nextMid)
            if at > time { return }
            if nextArrival <= nextMid {
                var f = frames[next]; next += 1
                // The engine takes the anchor when it starts the pair.
                f.anchor = pacer.frameArrived(id: f.id, decodedTime: f.decoded, generated: f.id > 1 ? generated : 0)
                if f.id > 1 { pending.append(f) }
            } else {
                let f = pending.remove(at: pending.firstIndex { $0.midDone == nextMid }!)
                pacer.noteReadyOffset(f.midDone - f.anchor)
                pacer.midFinished(id: f.id, ok: true)
            }
            if let lt = latch, held != nil, at < lt - lead {
                held = nil
                decide(pacer.tick(target: lt, refresh: 1 / hz, recheck: true), lt)
            }
        }
    }

    var n = 0
    while grid0 + Double(n) * r < seconds {
        let target = grid0 + Double(n) * r
        held = nil
        committed = false
        while let f = inFlight.first, f.glass <= target - r {
            inFlight.removeFirst()
            pacer.notePresented(target: f.target, presented: f.glass)
        }
        deliver(upTo: target - r, latch: nil)
        let seen = pacer.counters
        decide(pacer.tick(target: target, refresh: 1 / hz), target)
        deliver(upTo: target - lead, latch: target)
        if !committed && backlog > 0 { backlog -= 1 }
        previousEmpty = !committed
        let c = pacer.counters
        if c.phaseEarlier > seen.phaseEarlier { run.earlierSteps.append(target) }
        if c.phaseLater > seen.phaseLater { run.laterSteps.append(target) }
        if c.queueDrains > seen.queueDrains { run.drains.append(target) }
        n += 1
    }
    run.counters = pacer.counters
    return run
}

struct FramePacerTests {
    @Test func resetsInterpolationBudgetOnlyWhenRequested() {
        let pacer = FramePacer()
        let startup = pacer.budget
        for _ in 0..<10 { pacer.noteReadyOffset(0.03) }
        let learned = pacer.budget
        #expect(learned > startup)

        pacer.reset(keepingBudget: true)
        #expect(pacer.budget == learned)

        pacer.reset()
        pacer.noteReadyOffset(0.012)
        #expect(pacer.budget == startup)
    }

    /// 29.97 fps on 60.00 Hz beats by one refresh every ~16.7 s. Smooth mode must follow it with
    /// single 50 ms steps and never let the phase creep later: no latency growth over 60 s.
    @Test func smoothHasNoLatencyGrowthAt2997On60() {
        let run = simulatePacer(fps: 29.97, seconds: 61, interpMs: { _ in 12.4 })
        #expect(run.a2p.count > 1700)
        // No trend: the sawtooth averages out (a creeping phase gains >= 16.7 ms per minute).
        #expect(abs(run.slope) < 0.1, "a2p trend \(run.slope) ms/s")
        // Later windows are no worse than earlier ones.
        let firstHalf = run.a2p.filter { $0.t < 31 }.map(\.ms).max()!
        let secondHalf = run.a2p.filter { $0.t >= 31 }.map(\.ms).max()!
        #expect(secondHalf <= firstHalf + 2, "max a2p \(firstHalf) -> \(secondHalf) ms")
        // Bounded to the one refresh the beat forces (plus arrival jitter).
        let sorted = run.a2p.map(\.ms).sorted()
        let spread = sorted[sorted.count * 99 / 100] - sorted[sorted.count / 100]
        #expect(spread < 1000.0 / 60 + 6, "a2p p1..p99 spread \(spread) ms")
        // Even cadence: 33 ms, plus one 50 ms step per beat.
        #expect(run.realIntervals.allSatisfy { $0 == 2 || $0 == 3 })
        #expect(run.realIntervals.filter { $0 == 3 }.count <= 5)
        #expect(run.counters.phaseEarlier == 0)
    }

    /// 30 fps on 60 Hz with slack: perfectly even 33 ms intervals and no missed deadlines.
    @Test func smoothHoldsEvenCadenceAt30On60() {
        let run = simulatePacer(fps: 30, seconds: 31, interpMs: { _ in 10 })
        #expect(run.realIntervals.allSatisfy { $0 == 2 })
        #expect(run.rescues == 0)
        #expect(run.counters.phaseLater == 0)
    }

    /// A 0.5 s GPU slowdown pushes the phase one refresh later; once the budget is back, one
    /// 17 ms step returns it to the minimum.
    @Test func smoothReturnsToMinimumPhaseAfterSlowdown() {
        let run = simulatePacer(fps: 30, seconds: 61, interpMs: { $0 >= 20 && $0 < 20.5 ? 30 : 10 })
        let before = run.mean(5, 19), after = run.mean(40, 61)
        #expect(after <= before + 1, "a2p \(before) ms before the slowdown, \(after) ms after")
        #expect(run.counters.phaseLater >= 1)
        #expect(run.counters.phaseEarlier >= 1)
        #expect(run.realIntervals.filter { $0 != 2 }.count <= 4)
    }

    /// A present that misses its vsync leaves the 2-drawable queue one deep: every later frame
    /// would reach the glass a refresh late. The pacer leaves out one generated frame to drain it.
    @Test func drainsPresentBacklog() {
        let run = simulatePacer(fps: 30, seconds: 41, interpMs: { _ in 10 }, stallAt: 20)
        let before = run.mean(5, 19.5), after = run.mean(22, 41)
        #expect(run.counters.queueDrains == 1)
        #expect(after <= before + 1, "a2p \(before) ms before the stall, \(after) ms after")
    }

    /// A lasting lag step that draining does not remove gets one drain, then becomes the norm.
    @Test func drainsOnceForPersistentLag() {
        let run = simulatePacer(fps: 30, seconds: 41, interpMs: { _ in 10 }, lagStepAt: 20)
        #expect(run.counters.queueDrains == 1)
        #expect(run.realIntervals.filter { $0 != 2 }.count <= 2)
    }

    /// A TV whose glass is always one refresh after the target, except a present right after an
    /// empty vsync (and a few at the start), which lands on target. The usual lag is that one
    /// refresh: no drain, ever (each drain would be a visible 50 ms hitch).
    @Test(arguments: [0, 5])
    func noDrainsWhenLagStaysOneRefresh(onTime: Int) {
        let run = simulatePacer(fps: 29.97, seconds: 61, interpMs: { _ in 12 }, tvLag: true, onTimePresents: onTime)
        #expect(run.counters.queueDrains == 0, "drains at \(run.drains)")
        #expect(run.realIntervals.filter { $0 == 1 }.isEmpty)
    }

    /// The same TV with a real stall: one drain, and the latency returns to where it was.
    @Test func drainsRealBacklogOnOneRefreshDisplay() {
        let run = simulatePacer(fps: 30, seconds: 41, interpMs: { _ in 10 }, stallAt: 20, tvLag: true)
        let before = run.mean(5, 19.5), after = run.mean(22, 41)
        #expect(run.counters.queueDrains == 1)
        #expect(after <= before + 1, "a2p \(before) ms before the stall, \(after) ms after")
    }

    /// A stall during the learning period (start-up) is still drained once learning ends.
    @Test func drainsStallDuringLearning() {
        let run = simulatePacer(fps: 30, seconds: 21, interpMs: { _ in 10 }, stallAt: 0.8)
        #expect(run.counters.queueDrains == 1)
        let clean = simulatePacer(fps: 30, seconds: 21, interpMs: { _ in 10 })
        #expect(run.mean(5, 21) <= clean.mean(5, 21) + 1, "a2p \(run.mean(5, 21)) ms vs \(clean.mean(5, 21)) ms without the stall")
    }

    /// Interpolation with a slow tail: p50 12 ms with ~3% of frames at 16.6 ms (p99 ~ one refresh).
    /// No earlier step is followed by a later one within 10 s, and the cadence stays 33 ms.
    @Test(arguments: [30.0, 29.97])
    func noPhaseFlappingWithInterpTailNearRefresh(fps: Double) {
        let tail: (Double) -> Double = { t in Int((t * fps).rounded()) % 31 == 0 ? 16.6 : 12 }
        let run = simulatePacer(fps: fps, seconds: 91, interpMs: tail, tvLag: true)
        #expect(run.flaps() == 0, "earlier at \(run.earlierSteps), later at \(run.laterSteps)")
        #expect(run.counters.queueDrains == 0)
        #expect(Double(run.realIntervals.filter { $0 == 2 }.count) >= Double(run.realIntervals.count) * 0.99)
    }

    // MARK: 120 Hz

    /// 60 fps output on 120 Hz: every image held exactly two refreshes (16.7 ms), 33 ms between
    /// real frames, no drains or drops.
    @Test func evenTwoRefreshCadenceAt60On120() {
        let run = simulatePacer(fps: 30, hz: 120, seconds: 31, interpMs: { _ in 12 })
        #expect(run.holds.count > 1700)
        #expect(run.holds.allSatisfy { $0 == 2 }, "holds \(run.holdCounts)")
        #expect(run.realIntervals.allSatisfy { $0 == 4 })
        #expect(run.generatedPerPair.allSatisfy { $0 == 1 })
        #expect(run.counters.queueDrains == 0)
        #expect(run.counters.droppedReal == 0)
        #expect(run.counters.phaseLater == 0)
    }

    /// The 8.33 ms grid lets the mid frame (and its real frame) go out up to a refresh earlier
    /// than the 16.7 ms grid would: never later on average, a refresh earlier for interpolation
    /// times that just miss a 60 Hz slot.
    @Test(arguments: [12.0, 14, 18])
    func gridOf120IsNoLaterThan60(interpMs: Double) {
        var at60 = 0.0, at120 = 0.0
        for seed in UInt64(1)...4 {
            at60 += simulatePacer(fps: 30, hz: 60, seconds: 21, interpMs: { _ in interpMs }, seed: seed).mean(5, 21) / 4
            at120 += simulatePacer(fps: 30, hz: 120, seconds: 21, interpMs: { _ in interpMs }, seed: seed).mean(5, 21) / 4
        }
        #expect(at120 <= at60 + 0.5, "a2p \(at60) ms at 60 Hz, \(at120) ms at 120 Hz")
        if interpMs == 14 { #expect(at120 <= at60 - 6, "a2p \(at60) ms at 60 Hz, \(at120) ms at 120 Hz") }
    }

    /// 120 fps output on 120 Hz: three generated frames per pair, then the real one, each up for
    /// one refresh.
    @Test func fourImageCadenceAt120On120() {
        let run = simulatePacer(fps: 30, hz: 120, seconds: 31, generated: 3, interpMs: { _ in 14 })
        #expect(run.holds.count > 3400)
        #expect(run.holds.allSatisfy { $0 == 1 }, "holds \(run.holdCounts)")
        #expect(run.realIntervals.allSatisfy { $0 == 4 })
        #expect(run.generatedPerPair.allSatisfy { $0 == 3 })
        #expect(run.counters.queueDrains == 0)
        #expect(run.counters.droppedReal == 0)
    }

    /// A glass time one refresh after the target for good (TV / compositor), at both output rates
    /// on 120 Hz: that is the usual lag, never a backlog.
    @Test(arguments: [1, 3])
    func noDrainsAtStableOneRefreshLagOn120(generated: Int) {
        let steady = simulatePacer(fps: 29.97, hz: 120, seconds: 61, generated: generated, interpMs: { _ in 12 }, lagStepAt: 0)
        #expect(steady.counters.queueDrains == 0, "drains at \(steady.drains)")
        let tv = simulatePacer(fps: 29.97, hz: 120, seconds: 61, generated: generated, interpMs: { _ in 12 }, tvLag: true, onTimePresents: 5)
        #expect(tv.counters.queueDrains == 0, "drains at \(tv.drains)")
        #expect(tv.counters.droppedReal == 0)
    }

    /// At 60 fps on 120 Hz the glass - target lag steps up one refresh mid-session (8.3 -> 16.7 ms).
    /// Every image is held two refreshes, so the vsync after each present is free and a one-refresh
    /// slip cannot back the queue up: no drain.
    @Test func noDrainForOneRefreshLagStepAt60On120() {
        let run = simulatePacer(fps: 30, hz: 120, seconds: 41, interpMs: { _ in 12 }, lagStepAt: 20)
        #expect(run.counters.queueDrains == 0, "drains at \(run.drains)")
        // The step itself shows as one 5-refresh interval on the glass.
        #expect(run.realIntervals.filter { $0 != 4 }.count <= 1)
    }

    /// 29.97 fps on 120 Hz: the beat costs a one-refresh step every ~8 s, never latency growth.
    @Test(arguments: [1, 3])
    func noLatencyGrowthAt2997On120(generated: Int) {
        let run = simulatePacer(fps: 29.97, hz: 120, seconds: 61, generated: generated, interpMs: { _ in 12.4 })
        #expect(abs(run.slope) < 0.1, "a2p trend \(run.slope) ms/s")
        #expect(run.realIntervals.allSatisfy { $0 == 4 || $0 == 5 })
        #expect(run.realIntervals.filter { $0 == 5 }.count <= 10)
        #expect(run.counters.droppedReal == 0)
    }

    /// 120 fps output with a stall: the queue backs up (every vsync has a commit), one generated
    /// frame is left out, and latency returns to where it was.
    @Test func drainsRealBacklogAt120On120() {
        let run = simulatePacer(fps: 30, hz: 120, seconds: 41, generated: 3, interpMs: { _ in 12 }, stallAt: 20)
        let before = run.mean(5, 19.5), after = run.mean(22, 41)
        #expect(run.counters.queueDrains == 1)
        #expect(after <= before + 1, "a2p \(before) ms before the stall, \(after) ms after")
    }

    /// One drain at 120 fps output leaves out one generated image and nothing else: every other
    /// image is still held one refresh (hold 1) and every other pair still shows three generated
    /// frames.
    @Test func singleDrainKeeps120Cadence() {
        let run = simulatePacer(fps: 30, hz: 120, seconds: 41, generated: 3, interpMs: { _ in 12 }, stallAt: 20)
        #expect(run.counters.queueDrains == 1)
        #expect(run.holds.filter { $0 != 1 }.count <= 2, "holds \(run.holdCounts)")
        #expect(run.generatedPerPair.filter { $0 != 3 }.count <= 1, "gen/pair \(run.generatedPerPair.filter { $0 != 3 })")
        #expect(run.counters.droppedReal == 0)
    }

    /// A link that ticks every other refresh of a 120 Hz panel while reporting 8.33 ms (a 60 Hz
    /// pin): the pacer works on the 16.7 ms grid it actually gets.
    @Test func followsPinnedLinkPeriod() {
        let run = simulatePacer(fps: 30, hz: 120, seconds: 31, tickEvery: 2, interpMs: { _ in 12 })
        #expect(run.holds.allSatisfy { $0 == 2 }, "holds \(run.holdCounts)")
        #expect(run.realIntervals.allSatisfy { $0 == 4 })
        #expect(run.counters.queueDrains == 0)
        #expect(run.counters.droppedReal == 0)
    }

    /// A 120 Hz session at start-up: interpolation ~30 ms (budget near a whole
    /// source interval) on a link ticking every other refresh, deciding ~10 ms ahead of the
    /// target. With 120 fps output the real frame sits three images after the first generated
    /// one and comes due more than two source intervals after its anchor; the next arrival must
    /// not evict a real frame whose generated frames are already on screen.
    @Test(arguments: [1, 3])
    func noEvictionOnceMidIsShown(generated: Int) {
        let pacer = FramePacer()
        pacer.reset()
        let r = 1.0 / 120, tick = 2 * r, ahead = 0.010, interp = 0.030
        for _ in 0..<10 { pacer.noteReadyOffset(interp) }
        var nextFrame = 0, shownReal = Set<UInt64>()
        var pending: [(id: UInt64, ready: Double)] = []
        for n in 0..<(60 * 10) {
            let target = 0.0037 + Double(n) * tick, now = target - ahead
            while 0.1 + Double(nextFrame) / 30 <= now {
                let id = UInt64(nextFrame + 1), t = 0.1 + Double(nextFrame) / 30
                pacer.frameArrived(id: id, decodedTime: t, generated: id > 1 ? generated : 0)
                if id > 1 { pending.append((id, t + interp)) }
                nextFrame += 1
            }
            for p in pending where p.ready <= now { pacer.midFinished(id: p.id, ok: true) }
            pending.removeAll { $0.ready <= now }
            if case let .real(id, _) = pacer.tick(target: target, refresh: r, deadline: now + tick - 0.0015) { shownReal.insert(id) }
        }
        #expect(pacer.counters.droppedReal == 0)
        #expect(shownReal.count >= 290)
    }
}
