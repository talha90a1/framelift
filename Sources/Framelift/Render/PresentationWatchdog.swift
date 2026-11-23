// SPDX-License-Identifier: AGPL-3.0-only
// Presentation watchdog (pure: host seconds in, transitions out), keyed on the last present that
// reached the glass rather than on presents being made:
//   * stalled: the window is visible, frames are arriving, presents are committed, and none has
//     reached the glass for `stallAfter`. Reported once at onset;
//   * paused: the window is occluded / hidden (presents are expected to be dropped);
//   * resumed: the first present on the glass after a stall, the window becoming visible after
//     a pause, or a display-link tick after a gap longer than `stallAfter`.
import Foundation

struct PresentationWatchdog {
    static let stallAfter = 0.25

    enum Transition: Equatable {
        /// Nothing on the glass (presents committed since, how long), while visible.
        case stalled(committed: Int, for: Double)
        case paused
        /// `reason` for the event log.
        case resumed(reason: String)
    }

    enum State: Equatable { case live, stalled, paused }

    private(set) var state = State.live
    private var lastGlass: Double?
    private var committedSinceGlass = 0
    private var lastFrame: Double?
    private var lastTick: Double?
    private var visible = true
    private var stalledAt = 0.0

    /// A real frame arrived from the stream.
    mutating func noteFrame(at now: Double) { lastFrame = now }

    /// A present was committed.
    mutating func noteCommitted(at now: Double) {
        committedSinceGlass += 1
        if lastGlass == nil { lastGlass = now }   // the clock starts at the first present
    }

    /// A present reached the glass.
    mutating func noteGlass(at now: Double) -> Transition? {
        lastGlass = now
        committedSinceGlass = 0
        guard state == .stalled else { return nil }
        state = .live
        return .resumed(reason: String(format: "presents reach the glass again after %.0f ms", (now - stalledAt) * 1000))
    }

    /// The window's visibility changed (occlusion, hidden, minimised).
    mutating func noteVisible(_ isVisible: Bool, at now: Double) -> Transition? {
        guard isVisible != visible else { return nil }
        visible = isVisible
        if !isVisible {
            state = .paused
            return .paused
        }
        let was = state
        state = .live
        lastGlass = now
        committedSinceGlass = 0
        return was == .paused ? .resumed(reason: "window visible") : nil
    }

    /// A display-link tick at `now`; a gap since the last one means the link was paused.
    mutating func noteTick(at now: Double) -> Transition? {
        defer { lastTick = now }
        guard let last = lastTick, now - last > Self.stallAfter else { return nil }
        let gap = now - last
        lastGlass = now
        committedSinceGlass = 0
        guard visible else { return nil }
        state = .live
        return .resumed(reason: String(format: "display link resumed after %.0f ms", gap * 1000))
    }

    /// Checked every tick: the stall onset (once).
    mutating func check(now: Double) -> Transition? {
        guard state == .live, visible, let glass = lastGlass, committedSinceGlass > 0,
              let frame = lastFrame, now - frame < Self.stallAfter * 2,
              now - glass > Self.stallAfter else { return nil }
        state = .stalled
        stalledAt = now
        return .stalled(committed: committedSinceGlass, for: now - glass)
    }
}
