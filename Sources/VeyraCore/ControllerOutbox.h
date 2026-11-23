// SPDX-License-Identifier: AGPL-3.0-only
// Framelift: controller states between vr_session_set_controller (the app's input queue) and
// the session owner, which hands them to ChiakiBackend::submitController.
//
// The ordering rules are PushFPS's ControllerQueue (veyra/remoteplay/ControllerQueue.h): sticks and
// motion coalesce into the newest waiting state, button / touch / trigger-band edges keep their
// order, the queue is bounded, so a press and release between two owner reads both reach chiaki.
//
// VRControllerState carries one IMU sample per call: each pushed state gets it as motionSamples[0]
// (once, by timestamp) and the queue's merge keeps them all, in order. Pure: the caller holds its
// own lock and passes its own clock.
//
// Silence (no push for ControllerQueue::kFresh100ns while states wait) answers with a neutral
// state, as upstream. The app sends a keepalive state every 5 ms, so this only happens when the app
// stops sending. The owner only takes while states wait, so an idle queue never turns neutral.
#pragma once
#include "veyra/remoteplay/ControllerQueue.h"
#include <vector>

namespace veyra::remoteplay {
class ControllerOutbox {
public:
    // False when the state made the queue overflow (fail-safe neutral queued first).
    bool push(ControllerState state, HostTime now) {
        if (state.motionValid && state.motionTimestampUs > lastQueuedMotionUs_) {
            state.motionSamples[0] = {state.gyro, state.accel, state.motionTimestampUs};
            state.motionSampleCount = 1;
            lastQueuedMotionUs_ = state.motionTimestampUs;
        } else {
            state.motionSampleCount = 0;
        }
        return queue_.push(std::move(state), now);
    }
    // Appends every waiting state to `out`, oldest first, to be submitted in that order.
    void drain(HostTime now, std::vector<ControllerState>& out) {
        while (queue_.pending()) out.push_back(queue_.take(now));
    }
    std::size_t pending() const { return queue_.pending(); }
    const ControllerQueue::Stats& stats() const { return queue_.stats(); }

private:
    ControllerQueue queue_;
    std::uint64_t lastQueuedMotionUs_ = 0;
};
} // namespace veyra::remoteplay
