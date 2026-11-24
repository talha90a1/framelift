// SPDX-License-Identifier: AGPL-3.0-only
// Slot-based presentation pacing on the display-link grid (pure logic: no threads, no Metal).
// A real frame is never moved later than its slot; decisions are made one vsync at a time.
import Foundation

enum MidState {
    case none  // not requested (first frame, discontinuity, display too slow)
    case pending
    case ready  // all of the pair's generated frames
    case failed  // scene cut, or no content at all by the deadline
}

enum PacerDecision: Equatable {
    /// Present this entry's real frame (`early`: shown in a generated slot because there is none).
    case real(id: UInt64, early: Bool)
    /// Present this entry's generated frame `index` (0 ..< generated, phase (index + 1) / (n + 1)).
    case generated(id: UInt64, index: Int)
    /// Generated frames still running: present `index` if they complete before `deadline`,
    /// else `expireWait`.
    case waitForMid(id: UInt64, index: Int, deadline: Double)
    /// Nothing new for this vsync.
    case hold
}

struct PacerCounters {
    var droppedReal: UInt64 = 0  // real frames never shown (replaced by a newer one)
    var skippedMid: UInt64 = 0  // pairs whose generated slot showed a real frame instead
    var repeatedSlots: UInt64 = 0  // vsyncs that should have had new content but did not
    var phaseEarlier: UInt64 = 0  // cadence moved one refresh earlier (budget slack)
    var phaseLater: UInt64 = 0  // cadence moved later (missed deadlines)
    var queueDrains: UInt64 = 0  // generated frames left out to drain a present backlog
}

final class FramePacer {
    final class Entry {
        let id: UInt64
        let decodedTime: Double
        let anchor: Double
        /// Generated frames wanted before this real frame (0: none).
        let generated: Int
        var mid: MidState
        var firstSlot: Double?
        var step: Double = 0
        var realSlot: Double?
        var nextIndex = 0
        var shownCount = 0
        var plannedMid: Double?
        var midShown: Bool { shownCount > 0 }
        var midSkipped: Bool { mid != .none && shownCount == 0 }
        init(id: UInt64, decodedTime: Double, anchor: Double, generated: Int, mid: MidState) {
            self.id = id
            self.decodedTime = decodedTime
            self.anchor = anchor
            self.generated = generated
            self.mid = mid
        }
    }

    /// Display fast enough for generated frames (engine: 2 x displayHz >= 3 x sourceFPS).
    var generatesFrames = true
    /// Nominal source interval until measured (s).
    var nominalInterval: Double = 1.0 / 30
    /// Time the render thread needs before a vsync to get a frame on it (s).
    var commitLead: Double = 0.002

    private(set) var entries: [Entry] = []
    /// Period of the grid slots are placed on: the display link's tick period (s).
    private(set) var refresh: Double = 1.0 / 60
    private(set) var interval: Double = 1.0 / 30
    private static let startupBudget = 0.0165
    private(set) var budget = FramePacer.startupBudget
    private(set) var counters = PacerCounters()
    private var smoothed: Double?
    private var outlierSide = 0
    private var lastDecoded: Double?
    private var lastNewContentSlot: Double?
    private var readySamples = PercentileWindow(capacity: 90)
    private var lastMidSlot: (slot: Double, anchor: Double)?
    /// Hold of the latest scheduled pair's images, in refreshes (1 until a pair is scheduled).
    private(set) var holdSteps = 1

    private var tickDeltas = PercentileWindow(capacity: 31)
    private var lastTickTarget: Double?

    /// Pairs in a row with p99 slack for one refresh before the cadence steps earlier.
    var earlierAfterPairs = 60
    /// No earlier step for this long (s, anchor time) after a later step.
    var earlierBlockAfterLater = 10.0
    private var earlyStreak = 0
    private var lastLaterAnchor: Double?
    private var outcomes: [Bool] = []  // last 8 first-slot deadlines: true = missed
    private var recentMisses: Int { outcomes.lazy.filter { $0 }.count }

    /// Presents (after a reset or display change) before the usual lag is trusted; no drain before.
    static let lagLearnPresents = 60
    /// Presents after a drain whose median becomes the usual lag.
    static let drainSettlePresents = 20
    /// Minimum time between drains (s), unless the lag has grown past the last drain's.
    static let drainMinGap = 10.0
    private var lagWindow = PercentileWindow(capacity: 240)
    private var lagBaseline: Double?
    private var learnRun: (level: Double, count: Int) = (0, 0)
    private var learnQuietLevel: Double?
    private var backlogStreak = 0
    private var drainPending = false
    private var postDrainLags: [Double]?
    private var lastDrain: (at: Double, lag: Double)?
    private(set) var presentLagging = false
    /// Deadline misses while this is true are the present backlog's doing, not the interpolator's.
    /// Glass - target and its usual value (s) when the last drain was decided.
    private(set) var drainLag: (lag: Double, usual: Double) = (0, 0)
    /// A lag this much above the usual one is a present backlog: 0.9 of an image hold.
    private var backlogStep: Double { refresh * 0.9 * Double(holdSteps) }

    /// Refreshes each image is held when a pair carries `n` generated frames.
    func imageSteps(generated n: Int) -> Int { max(1, Int((interval / Double(n + 1) / refresh).rounded())) }

    // MARK: Inputs

    func reset(keepingBudget: Bool = false) {
        entries.removeAll()
        smoothed = nil
        lastDecoded = nil
        outlierSide = 0
        lastNewContentSlot = nil
        lastMidSlot = nil
        interval = nominalInterval
        earlyStreak = 0
        lastLaterAnchor = nil
        outcomes.removeAll()
        holdSteps = 1
        if !keepingBudget {
            readySamples = PercentileWindow(capacity: readySamples.capacity)
            budget = Self.startupBudget
        }
        resetPresentLag()
    }

    /// Adds a real frame; returns its anchor. `generated`: generated frames for the pair (0, 1 or 3).
    @discardableResult
    func frameArrived(id: UInt64, decodedTime t: Double, generated: Int) -> Double {
        if let last = lastDecoded {
            let d = t - last
            if d > nominalInterval * 0.5 && d < nominalInterval * 1.5 {
                interval += (d - interval) * 0.02
            }
        } else {
            interval = nominalInterval
        }
        lastDecoded = t
        let anchor = smooth(t)
        // Never keep more than one real frame queued behind the newest one, except one whose
        // generated frame is already on screen (evicting it would cut the pair short).
        while entries.count >= 3 || (entries.count == 2 && !entries[0].midShown) {
            noteDropped(entries.removeFirst())
        }
        let n = generatesFrames ? max(0, generated) : 0
        entries.append(Entry(id: id, decodedTime: t, anchor: anchor, generated: n, mid: n > 0 ? .pending : .none))
        return anchor
    }

    private func smooth(_ t: Double) -> Double {
        guard let prev = smoothed, t - prev < interval * 2.5, t > prev else {
            smoothed = t; outlierSide = 0
            return t
        }
        let predicted = prev + interval
        let err = t - predicted
        let tolerance = max(0.004, interval * 0.12)
        let anchor: Double
        if abs(err) <= tolerance {
            anchor = predicted + err * 0.1
            outlierSide = 0
        } else {
            let side = err > 0 ? 1 : -1
            if outlierSide == side {
                anchor = t  // second outlier on the same side: follow it
                outlierSide = 0
            } else {
                anchor = predicted  // single outlier: keep the cadence
                outlierSide = side
            }
        }
        smoothed = anchor
        return anchor
    }

    func anchor(of id: UInt64) -> Double? { entries.first { $0.id == id }?.anchor }

    func noteReadyOffset(_ offset: Double) {
        // Not while backed up: the render thread is blocked in nextDrawable, delaying completions.
        guard offset > 0, offset < interval * 2, !presentLagging else { return }
        readySamples.add(offset)
        guard readySamples.count >= 5 else { return }
        let target = readySamples.percentile(0.95) + 0.0005
        if abs(target - budget) > 0.001 {  // hysteresis
            budget = min(target, interval)
        }
    }

    func midFinished(id: UInt64, ok: Bool) {
        guard let e = entries.first(where: { $0.id == id }), e.mid == .pending else { return }
        e.mid = ok ? .ready : .failed
    }

    func noteFallback() { counters.skippedMid += 1 }

    /// The frame committed for vsync `target` reached the glass at `presented` (host s, 0 when
    /// dropped). Lagging ~0.9 image hold above the usual lag for 10 presents in a row means the
    /// drawable queue stayed one deep: the next generated slot is left out once so it drains.
    func notePresented(target: Double, presented: Double) {
        guard presented > 0 else { return }
        let lag = presented - target
        guard lag > -refresh, lag < 0.25 else { return }
        guard let baseline = lagBaseline else { return learnPresentLag(lag) }
        postDrainLags?.append(lag)
        if let post = postDrainLags {
            if post.count >= Self.drainSettlePresents {
                lagWindow = PercentileWindow(capacity: lagWindow.capacity)
                for v in post { lagWindow.add(v) }
                lagBaseline = lagWindow.percentile(0.5)
                postDrainLags = nil
                backlogStreak = 0
            }
            presentLagging = false
            return
        }
        presentLagging = lag >= baseline + backlogStep
        if presentLagging {
            // Kept out of the usual lag: a backlog must not become the norm without a drain.
            backlogStreak += 1
        } else {
            backlogStreak = 0
            lagWindow.add(lag)
            lagBaseline = lagWindow.percentile(0.5)
        }
        let allowed = lastDrain.map { target - $0.at >= Self.drainMinGap || lag >= $0.lag + backlogStep } ?? true
        if backlogStreak >= 10 && !drainPending && allowed {
            drainPending = true
            drainLag = (lag, baseline)
            lastDrain = (target, lag)
            backlogStreak = 0
        }
    }

    /// Learning the usual lag: no drains. Ends after lagLearnPresents with the median, or with
    /// the lowest level held for 10 presents in a row when the lag stepped up an image from it.
    private func learnPresentLag(_ lag: Double) {
        presentLagging = false
        lagWindow.add(lag)
        if abs(lag - learnRun.level) < refresh * 0.5 && learnRun.count > 0 {
            learnRun.count += 1
        } else {
            learnRun = (lag, 1)
        }
        if learnRun.count >= 10 { learnQuietLevel = min(learnQuietLevel ?? learnRun.level, learnRun.level) }
        guard lagWindow.count >= Self.lagLearnPresents else { return }
        let median = lagWindow.percentile(0.5)
        if let quiet = learnQuietLevel, median >= quiet + backlogStep {
            // Backed up since partway through learning: judge against the level before it.
            lagWindow = PercentileWindow(capacity: lagWindow.capacity)
            lagWindow.add(quiet)
            lagBaseline = quiet
        } else {
            lagBaseline = median
        }
    }

    /// Forget the usual present lag and the tick period (display or display-link change).
    func resetPresentLag() {
        lagWindow = PercentileWindow(capacity: lagWindow.capacity)
        lagBaseline = nil
        learnRun = (0, 0)
        learnQuietLevel = nil
        backlogStreak = 0
        drainPending = false
        postDrainLags = nil
        lastDrain = nil
        presentLagging = false
        tickDeltas = PercentileWindow(capacity: tickDeltas.capacity)
        lastTickTarget = nil
    }

    // MARK: Display link

    /// The grid period: the reported refresh, or a whole multiple of it when the display link
    /// ticks only every n refreshes (median of the last 31 tick spacings).
    private func updateRefresh(target: Double, reported r: Double, recheck: Bool) {
        guard r > 0.002 && r < 0.05 else { return }
        if !recheck {
            if let last = lastTickTarget {
                let d = target - last
                if d > r * 0.5 && d < r * 4.5 { tickDeltas.add(d) }
            }
            lastTickTarget = target
        }
        var period = r
        if tickDeltas.count >= 8 {
            let m = tickDeltas.percentile(0.5)
            let n = (m / r).rounded()
            if n >= 2 && abs(m - n * r) < r * 0.25 { period = n * r }
        }
        refresh = period
    }

    /// Decide what to show at vsync `target`. `recheck`: the same vsync again (late latch); does
    /// not count repeats. `deadline`: latest commit time (CAMetalDisplayLink callbacks run several
    /// refreshes ahead of their target, so the engine passes the next callback time).
    func tick(target: Double, refresh r: Double, deadline: Double? = nil, recheck: Bool = false) -> PacerDecision {
        updateRefresh(target: target, reported: r, recheck: recheck)
        let commitBy = deadline ?? (target - commitLead)
        // Slot times are compared on the commit-deadline axis; `shift` maps them to targets.
        let shift = target - commitBy
        let eps = refresh * 0.25

        for e in entries where e.realSlot == nil {
            if generatesFrames && e.mid != .none {
                let slot = e.plannedMid ?? planSmoothSlot(e, natural: e.anchor + budget + shift, target: target, eps: eps)
                e.plannedMid = slot
                if target + eps >= slot {
                    // The planned slot even if this tick is late: a delayed callback must not re-phase.
                    let steps = imageSteps(generated: e.generated)
                    e.firstSlot = slot
                    e.step = Double(steps) * refresh
                    e.realSlot = slot + Double(e.generated) * e.step
                    holdSteps = steps
                }
            } else if commitBy + eps >= e.decodedTime {
                // No generated frame: the next vsync from its actual decode time (no smoothing delay).
                e.realSlot = target
            }
        }

        // 1. A real frame whose slot has come: show the newest one, drop older ones.
        if let idx = entries.lastIndex(where: { ($0.realSlot ?? .infinity) <= target + eps }) {
            let e = entries[idx]
            for old in entries[..<idx] { noteDropped(old) }
            if e.midSkipped { counters.skippedMid += 1 }
            entries.removeFirst(idx + 1)
            lastNewContentSlot = target
            return .real(id: e.id, early: false)
        }

        // 2. The oldest entry's next generated slot (the newest one due, after a late tick).
        if let e = entries.first, let first = e.firstSlot, e.nextIndex < e.generated,
            first + Double(e.nextIndex) * e.step <= target + eps
        {
            let due = min(e.generated - 1, Int(((target + eps - first) / e.step).rounded(.down)))
            e.nextIndex = max(e.nextIndex, due)
            if drainPending {
                drainPending = false
                postDrainLags = []
                e.nextIndex += 1
                counters.queueDrains += 1
                return .hold
            }
            switch e.mid {
            case .ready:
                return showReady(e, target: target)
            case .pending:
                return .waitForMid(id: e.id, index: e.nextIndex, deadline: commitBy)
            case .failed, .none:
                return showEarly(e, target: target)
            }
        }

        // 3. Nothing new: count it when the cadence expected new content here.
        if !recheck, let last = lastNewContentSlot {
            let gap = target - last
            let expected = generatesFrames ? Double(holdSteps) * refresh : max(refresh, (interval / refresh).rounded() * refresh)
            if gap > expected + refresh * 0.5, gap < interval * 2.5 {
                counters.repeatedSlots += 1
                lastNewContentSlot = last + refresh  // count every missing slot once
            }
        }
        return .hold
    }

    func resolveWait(id: UInt64, target: Double) -> PacerDecision {
        guard let e = entries.first, e.id == id else { return .hold }
        if e.mid == .ready { return showReady(e, target: target) }
        return showEarly(e, target: target)
    }

    /// Commit deadline passed without the interpolator's frames (a blend may stand in).
    func expireWait(id: UInt64, target: Double) -> PacerDecision {
        guard let e = entries.first, e.id == id else { return .hold }
        if e.shownCount == 0 { noteDeadline(missed: true) }
        if e.mid == .ready { return showGenerated(e, target: target) }
        return showEarly(e, target: target)
    }

    // MARK: Cadence

    /// First slot (target axis) for a pair: the previous pair's cadence, stepped one refresh
    /// earlier after sustained p99 slack, or later only when deadlines are missed.
    private func planSmoothSlot(_ e: Entry, natural: Double, target: Double, eps: Double) -> Double {
        let r = refresh
        // First vsync on this tick's grid whose commit deadline meets the budget (0.5 ms grace).
        func firstFeasible(grace: Double = 0.0005) -> Double { target + max(0, ((natural - grace - target) / r).rounded(.up)) * r }
        guard let last = lastMidSlot, e.anchor > last.anchor, e.anchor - last.anchor < interval * 2.5 else {
            // (Re)lock: the first vsync up to a quarter refresh short of the budget; the earlier
            // step corrects it once the stream has caught up.
            let slot = firstFeasible(grace: eps)
            lastMidSlot = (slot, e.anchor)
            earlyStreak = 0
            outcomes.removeAll()
            return slot
        }
        let expected = last.slot + max(1, ((e.anchor - last.anchor) / r).rounded()) * r
        let slack = expected - natural  // >= 0: the cadence slot meets the budget
        // An earlier step needs slack against p99 + 1 ms, not just the p95 budget.
        let tail = max(0, readySamples.percentile(0.99) + 0.001 - budget)
        let blocked = lastLaterAnchor.map { e.anchor - $0 < earlierBlockAfterLater } ?? false
        // Two whole refreshes of slack: step earlier after 15 pairs, blocked or not.
        let wide = slack >= 2 * r + 0.001
        var slot = expected
        // Misses while the present queue is backed up are its doing (drained separately).
        if slack < -eps || (slack < 0 && recentMisses >= 2 && !presentLagging) {
            slot = max(expected + r, firstFeasible())
            counters.phaseLater += 1
            // Only a step forced by missed deadlines blocks earlier steps, once the budget is measured.
            if slack >= -eps && readySamples.count >= readySamples.capacity { lastLaterAnchor = e.anchor }
            outcomes.removeAll()
            earlyStreak = 0
        } else if wide || (slack >= r + 0.001 + tail && !blocked) {
            earlyStreak += 1
            if earlyStreak >= (wide ? 15 : earlierAfterPairs) {
                slot = expected - r
                counters.phaseEarlier += 1
                earlyStreak = 0
            }
        } else {
            earlyStreak = 0
        }
        lastMidSlot = (slot, e.anchor)
        return slot
    }

    private func noteDeadline(missed: Bool) {
        outcomes.append(missed)
        if outcomes.count > 8 { outcomes.removeFirst() }
    }

    private func noteDropped(_ e: Entry) {
        counters.droppedReal += 1
        if e.midSkipped { counters.skippedMid += 1 }
    }

    private func showReady(_ e: Entry, target: Double) -> PacerDecision {
        if e.shownCount == 0 { noteDeadline(missed: false) }
        return showGenerated(e, target: target)
    }

    private func showGenerated(_ e: Entry, target: Double) -> PacerDecision {
        let index = min(e.nextIndex, e.generated - 1)
        e.nextIndex = index + 1
        e.shownCount += 1
        lastNewContentSlot = target
        return .generated(id: e.id, index: index)
    }

    private func showEarly(_ e: Entry, target: Double) -> PacerDecision {
        if e.shownCount == 0 { counters.skippedMid += 1 }
        entries.removeFirst()
        lastNewContentSlot = target
        return .real(id: e.id, early: true)
    }
}
