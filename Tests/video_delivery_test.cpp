// SPDX-License-Identifier: AGPL-3.0-only
#include "ControllerOutbox.h"
#include "VideoDeliveryWorker.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <thread>
#include <vector>

using namespace framelift::remoteplay;
using namespace std::chrono_literals;

#define CHECK(value) do { if (!(value)) { std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #value); std::abort(); } } while (0)

namespace {
struct Gate {
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false, released = false;
    void block() {
        std::unique_lock lock(mutex);
        entered = true; cv.notify_all();
        cv.wait(lock, [&] { return released; });
    }
    void awaitEntry() {
        std::unique_lock lock(mutex);
        CHECK(cv.wait_for(lock, 2s, [&] { return entered; }));
    }
    void release() { { std::lock_guard lock(mutex); released = true; } cv.notify_all(); }
};

void wake(void* user) noexcept { static_cast<framelift::VideoDeliveryWake*>(user)->notify(); }

VideoSample sample(const SessionInbox::Token& token, SampleKind kind, uint16_t index, bool idr = false) {
    VideoSample sample;
    sample.generation = token.generation(); sample.kind = kind; sample.codec = Codec::H265;
    sample.width = 1920; sample.height = 1080; sample.arrival100ns = monotonic100ns();
    if (kind == SampleKind::CodecConfig) {
        const std::vector<uint8_t> bytes{0,0,0,1,64,1,17,0,0,0,1,66,1,17,0,0,0,1,68,1,17};
        sample.payload = PaddedBytes::copy(bytes);
    } else {
        const std::vector<uint8_t> bytes{0,0,0,1,uint8_t(idr ? 38 : 2),1,17};
        sample.payload = PaddedBytes::copy(bytes); sample.wireFrameIndex = index;
    }
    return sample;
}

void blockedVideoDoesNotBlockOwnerAndRetainsRecovery() {
    SessionInbox inbox;
    framelift::VideoDeliveryWake signal;
    inbox.setWakeHook(wake, &signal);
    auto token = inbox.begin(monotonic100ns());
    Gate blocked;
    std::atomic<int> pictures{0}, recovered{0}, audio{0}, inputs{0};
    std::mutex inputMutex;
    ControllerOutbox controllers;
    framelift::VideoDeliveryWorker video(inbox, signal, [&](QueuedVideo unit) {
        const auto index = unit.sample.wireFrameIndex.value_or(0);
        if (index == 1) blocked.block();
        if (unit.resetDecoder && unit.configBefore) ++recovered;
        ++pictures;
    });
    std::jthread owner([&](std::stop_token stop) {
        while (!stop.stop_requested()) {
            std::vector<ControllerState> states;
            { std::lock_guard lock(inputMutex); controllers.drain(monotonic100ns(), states); }
            inputs += int(states.size());
            while (inbox.tryAudio()) ++audio;
            std::this_thread::sleep_for(1ms);
        }
    });
    CHECK(token.video(sample(token, SampleKind::CodecConfig, 0)));
    CHECK(token.video(sample(token, SampleKind::AccessUnit, 1, true)));
    blocked.awaitEntry();
    for (uint16_t index = 2; index <= 7; ++index) token.video(sample(token, SampleKind::AccessUnit, index));
    CHECK(inbox.snapshot().video.highWaterDepth <= 4);
    CHECK(inbox.snapshot().video.waitingForIdr);
    CHECK(inbox.snapshot().video.dropped > 0);
    for (int index = 0; index < 30; ++index) {
        ControllerState state; state.inputActive = true; state.leftX = int16_t(index);
        { std::lock_guard lock(inputMutex); controllers.push(state, monotonic100ns()); }
        if (index % 2 == 0) {
            PcmBlock block; block.generation = token.generation(); block.rate = 48000; block.channels = 2;
            block.firstSample = uint64_t(index / 2) * 480; block.arrival100ns = monotonic100ns();
            block.samples.resize(960);
            CHECK(token.audio(std::move(block)));
        }
        std::this_thread::sleep_for(5ms);
    }
    CHECK(pictures == 0);
    CHECK(inputs >= 10 && audio >= 10);
    CHECK(token.video(sample(token, SampleKind::AccessUnit, 8, true)));
    blocked.release();
    for (int tries = 0; tries < 200 && pictures < 2; ++tries) std::this_thread::sleep_for(1ms);
    CHECK(pictures == 2 && recovered == 2);
    video.stop();
    CHECK(!video.failed());
    CHECK(token.video(sample(token, SampleKind::AccessUnit, 9, true)));
    signal.notify(); std::this_thread::sleep_for(10ms);
    CHECK(pictures == 2);
    owner.request_stop(); owner.join();
    inbox.invalidate(); inbox.finishStop();
}

void stopWaitsForCallbackAndExceptionsJoin() {
    SessionInbox inbox;
    framelift::VideoDeliveryWake signal;
    inbox.setWakeHook(wake, &signal);
    auto token = inbox.begin(monotonic100ns());
    Gate blocked;
    std::atomic<bool> stopped{false};
    framelift::VideoDeliveryWorker video(inbox, signal, [&](QueuedVideo) { blocked.block(); });
    CHECK(token.video(sample(token, SampleKind::CodecConfig, 0)));
    CHECK(token.video(sample(token, SampleKind::AccessUnit, 1, true)));
    blocked.awaitEntry();
    std::jthread stopper([&] { video.stop(); stopped = true; });
    std::this_thread::sleep_for(10ms);
    CHECK(!stopped);
    blocked.release(); stopper.join(); CHECK(stopped);
    inbox.invalidate(); inbox.finishStop();

    auto next = inbox.begin(monotonic100ns());
    std::atomic<bool> completed{false}, callbackEntered{false};
    try {
        framelift::VideoDeliveryWorker unwinding(inbox, signal, [&](QueuedVideo) {
            callbackEntered = true;
            std::this_thread::sleep_for(10ms); completed = true;
        });
        CHECK(next.video(sample(next, SampleKind::CodecConfig, 0)));
        CHECK(next.video(sample(next, SampleKind::AccessUnit, 1, true)));
        for (int tries = 0; tries < 2000 && !callbackEntered; ++tries) std::this_thread::sleep_for(1ms);
        CHECK(callbackEntered);
        throw std::runtime_error("fixture");
    } catch (const std::runtime_error&) {}
    CHECK(completed);
    inbox.invalidate(); inbox.finishStop();
}
} // namespace

int main() {
    blockedVideoDoesNotBlockOwnerAndRetainsRecovery();
    stopWaitsForCallbackAndExceptionsJoin();
    std::puts("video delivery: blocked callback, bounded recovery, owner progress and join passed");
}
