// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 DosukaSOL and the PushFPS contributors. Part of PushFPS, a modified version of Veyra.
// Framelift: ported from PushFPS cea4552 (DosukaSOL/PushFPS); wired up in ControllerOutbox.h.
//
// Controller states from the interface to the session's owner. Pure: the caller holds its own lock
// and hands in its own clock.
//  - Edges (buttons, trigger part, touch contacts, inputActive) queue in order; levels (sticks, trigger
//    travel within a part, touch position, motion) only keep the newest, merged into the last waiting state.
//  - A state older than kFresh is dropped; what stands behind it is still sent.
//  - Neutral only when nothing true can be sent: no state for kFresh, input switched off, or more than
//    kMaxPending edges queued.
//  - Trigger travel is cut in four parts (released, light, half, full) so a short full pull is not
//    delivered as its last faint value.
#pragma once
#include "framelift/remoteplay/Types.h"
#include <algorithm>
#include <cstdint>
#include <deque>
#include <utility>
namespace framelift::remoteplay {
class ControllerQueue {
public:
    static constexpr HostTime kFresh100ns = 1000000;   // 100 ms
    static constexpr std::size_t kMaxPending = 16;
    struct Stats {
        std::uint64_t states = 0;        // handed in
        std::uint64_t merged = 0;        // replaced a waiting state with the same edges
        std::uint64_t expired = 0;       // dropped by itself after waiting too long
        std::uint64_t overflows = 0;     // more edges than kMaxPending: released, then the latest
        std::uint64_t silences = 0;      // the interface stopped reporting: released
        std::size_t highWaterPending = 0;
        HostTime highWaterAge100ns = 0;  // the longest a state that was sent had waited
    };
    // Which part of its travel a trigger is in.
    static constexpr int triggerPart(std::uint8_t travel) { return travel == 0 ? 0 : travel < 86 ? 1 : travel < 171 ? 2 : 3; }
    static bool sameEdges(const ControllerState& a, const ControllerState& b) {
        return a.inputActive == b.inputActive && a.buttons == b.buttons &&
               triggerPart(a.l2) == triggerPart(b.l2) && triggerPart(a.r2) == triggerPart(b.r2) &&
               a.touches[0].id == b.touches[0].id && a.touches[1].id == b.touches[1].id;
    }
    // False when the state made the queue overflow (the caller may log it; nothing else to do).
    bool push(ControllerState state, HostTime now) {
        stamp_ = now; ++stats_.states;
        // Input switched off cancels what was queued: nothing waits behind a release.
        if (!state.inputActive) pending_.clear();
        else if (!pending_.empty() && sameEdges(pending_.back().second, state)) {
            keepMotion(pending_.back().second, state);
            pending_.back() = {now, std::move(state)};
            ++stats_.merged;
            return true;
        }
        bool fits = true;
        if (pending_.size() >= kMaxPending) {
            pending_.clear(); pending_.push_back({now, ControllerState{}});
            ++stats_.overflows; fits = false;
        }
        pending_.push_back({now, std::move(state)});
        stats_.highWaterPending = std::max(stats_.highWaterPending, pending_.size());
        return fits;
    }
    // The state to send now. With nothing waiting, the one sent last (the console keeps what it has).
    ControllerState take(HostTime now) {
        if (now - stamp_ > kFresh100ns) {
            if (!pending_.empty() || !(last_ == ControllerState{})) ++stats_.silences;
            pending_.clear(); last_ = {}; return last_;
        }
        while (!pending_.empty() && now - pending_.front().first > kFresh100ns) { pending_.pop_front(); ++stats_.expired; }
        if (!pending_.empty()) {
            if (now > pending_.front().first) stats_.highWaterAge100ns = std::max(stats_.highWaterAge100ns, now - pending_.front().first);
            last_ = std::move(pending_.front().second); pending_.pop_front();
        }
        return last_;
    }
    std::size_t pending() const { return pending_.size(); }
    const Stats& stats() const { return stats_; }
private:
    // `next` replaces `previous`: its motion samples go behind those of `previous`, oldest first,
    // each newer than the one before, the newest sixteen kept.
    static void keepMotion(const ControllerState& previous, ControllerState& next) {
        if (!previous.motionValid || !next.motionValid) return;
        decltype(next.motionSamples) samples{}; std::size_t count = 0;
        const auto add = [&](const ControllerState::MotionSample& s) {
            if (!s.timestampUs || (count && s.timestampUs <= samples[count - 1].timestampUs)) return;
            if (count == samples.size()) { std::move(samples.begin() + 1, samples.end(), samples.begin()); --count; }
            samples[count++] = s;
        };
        for (std::size_t i = 0; i < std::min<std::size_t>(previous.motionSampleCount, previous.motionSamples.size()); ++i) add(previous.motionSamples[i]);
        for (std::size_t i = 0; i < std::min<std::size_t>(next.motionSampleCount, next.motionSamples.size()); ++i) add(next.motionSamples[i]);
        next.motionSamples = samples; next.motionSampleCount = std::uint8_t(count);
    }
    std::deque<std::pair<HostTime, ControllerState>> pending_;
    ControllerState last_{};
    HostTime stamp_ = 0;
    Stats stats_{};
};
} // namespace framelift::remoteplay
