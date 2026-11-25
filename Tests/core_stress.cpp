// SPDX-License-Identifier: GPL-3.0-only
// Multi-threaded stress for SessionInbox/VideoIngress/AudioIngress (the code between chiaki's
// callback threads and the bridge's delivery thread). Producers play chiaki (valid and corrupt
// samples, events, stale tokens across generations); one consumer plays the bridge owner; the
// controller cycles generations in the documented order. Run under TSan and ASan/UBSan.
// Before the stress run, deterministic regression checks: the Chiaki video-callback decision
// (only non-Annex-B payloads may return false) and the log redactor's hexdump rules.
// Usage: core_stress <seconds>
#include "ControllerOutbox.h"
#include "LogRedaction.h"
#include "framelift/remoteplay/SessionInbox.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <optional>
#include <random>
#include <string>
#include <thread>
#include <vector>

using namespace framelift::remoteplay;

namespace {
std::mutex tokenMutex;
std::optional<SessionInbox::Token> currentToken, staleToken;
std::atomic<bool> running{true};
std::atomic<uint64_t> produced{0}, accepted{0}, consumedVideo{0}, consumedAudio{0}, wakes{0}, violations{0};
std::mutex wakeMutex;
std::condition_variable wakeCv;
bool woken = false;

void onWake(void*) noexcept {
    {
        std::lock_guard lock(wakeMutex);
        woken = true;
    }
    wakeCv.notify_one();
    ++wakes;
}

std::vector<uint8_t> nal(std::initializer_list<uint8_t> header, std::mt19937& rng, std::size_t body) {
    std::vector<uint8_t> out{0, 0, 0, 1};
    out.insert(out.end(), header);
    for (std::size_t i = 0; i < body; ++i) out.push_back(uint8_t(rng() | 1)); // avoid accidental start codes
    return out;
}


// Regression: if a keyframe request gates the ingress and the callback returns false for P frames,
// Chiaki drops each reference frame and reports every following frame corrupt. Assert what Chiaki receives.
int regressionFailures = 0;
#define EXPECT(cond)                                                                   \
    do {                                                                               \
        if (!(cond)) {                                                                 \
            std::fprintf(stderr, "regression failed: %s (line %d)\n", #cond, __LINE__); \
            ++regressionFailures;                                                      \
        }                                                                              \
    } while (0)

VideoSample makeSample(const SessionInbox::Token& token, SampleKind kind, std::vector<uint8_t> bytes,
                       std::optional<uint16_t> frame = {}) {
    VideoSample s;
    s.generation = token.generation();
    s.kind = kind;
    s.codec = Codec::H265;
    s.width = 1920;
    s.height = 1080;
    s.wireFrameIndex = frame;
    s.arrival100ns = monotonic100ns();
    s.payload = PaddedBytes::copy(bytes);
    return s;
}

void regressionVideoCallback() {
    std::mt19937 rng(42);
    auto config = [&] {
        std::vector<uint8_t> out;
        for (uint8_t t : {32, 33, 34}) {
            auto n = nal({uint8_t(t << 1), 1}, rng, 8);
            out.insert(out.end(), n.begin(), n.end());
        }
        return out;
    };
    auto idr = [&] { return nal({19 << 1, 1}, rng, 300); };
    auto pframe = [&] { return nal({1 << 1, 1}, rng, 120); };
    QueueLimits limits;
    SessionInbox inbox(limits);
    auto token = inbox.begin(monotonic100ns());
    const auto g = token.generation();
    uint16_t frame = 1;
    auto deliver = [&](SampleKind kind, std::vector<uint8_t> bytes, std::optional<uint16_t> index) {
        return deliverChiakiVideo(token, makeSample(token, kind, std::move(bytes), index));
    };
    auto accepted = [&](VideoDelivery d) { return chiakiVideoCallbackResult(d); };

    // P frame before the first IDR: dropped by the ingress, accepted for Chiaki.
    auto d = deliver(SampleKind::AccessUnit, pframe(), frame++);
    EXPECT(d == VideoDelivery::Discarded && accepted(d));
    EXPECT(accepted(deliver(SampleKind::CodecConfig, config(), std::nullopt)));
    EXPECT(deliver(SampleKind::AccessUnit, idr(), frame++) == VideoDelivery::Queued);
    EXPECT(deliver(SampleKind::AccessUnit, pframe(), frame++) == VideoDelivery::Queued);
    while (inbox.tryVideo(monotonic100ns())) {}

    // App keyframe request (vr_session_request_idr): arms the console IDR request, never gates.
    inbox.requestIdr(g);
    EXPECT(inbox.takeIdrRequest(monotonic100ns()));
    d = deliver(SampleKind::AccessUnit, pframe(), frame++);
    EXPECT(d == VideoDelivery::Queued);
    EXPECT(!inbox.snapshot().video.waitingForIdr);
    while (inbox.tryVideo(monotonic100ns())) {}

    // Internal recovery gate (decodeFailed): P frames dropped by the ingress, still true for Chiaki.
    inbox.decodeFailed(g);
    for (int i = 0; i < 20; ++i) {
        d = deliver(SampleKind::AccessUnit, pframe(), frame++);
        EXPECT(d == VideoDelivery::Discarded && accepted(d));
    }
    EXPECT(deliver(SampleKind::AccessUnit, idr(), frame++) == VideoDelivery::Queued);
    {
        auto unit = inbox.tryVideo(monotonic100ns());
        EXPECT(unit && unit->resetDecoder && unit->configBefore);
    }

    // Queue full with no consumer: never a false return.
    for (int i = 0; i < int(limits.maxFrames) * 4; ++i) EXPECT(accepted(deliver(SampleKind::AccessUnit, pframe(), frame++)));
    while (inbox.tryVideo(monotonic100ns())) {}

    // Repeated frame index, frames lost, reference recovered, too old, bad dimensions: all accepted.
    EXPECT(accepted(deliver(SampleKind::AccessUnit, idr(), frame)));
    EXPECT(accepted(deliver(SampleKind::AccessUnit, pframe(), frame))); // same index again
    ++frame;
    {
        auto s = makeSample(token, SampleKind::AccessUnit, pframe(), frame++);
        s.framesLost = 3;
        EXPECT(accepted(deliverChiakiVideo(token, std::move(s))));
        s = makeSample(token, SampleKind::AccessUnit, pframe(), frame++);
        s.referenceRecovered = true;
        EXPECT(accepted(deliverChiakiVideo(token, std::move(s))));
        s = makeSample(token, SampleKind::AccessUnit, idr(), frame++);
        s.arrival100ns -= 5000000; // 500 ms old
        EXPECT(accepted(deliverChiakiVideo(token, std::move(s))));
        s = makeSample(token, SampleKind::AccessUnit, idr(), frame++);
        s.width = s.height = 0; // profile metadata missing
        EXPECT(accepted(deliverChiakiVideo(token, std::move(s))));
        s = makeSample(token, SampleKind::AccessUnit, config(), frame++); // valid Annex-B, wrong kind
        EXPECT(accepted(deliverChiakiVideo(token, std::move(s))));
    }

    // Genuinely malformed payloads are the only false returns.
    d = deliver(SampleKind::AccessUnit, {0x12, 0x34, 0x56, 0x78}, frame++);
    EXPECT(d == VideoDelivery::Malformed && !accepted(d));
    d = deliver(SampleKind::AccessUnit, {}, frame++);
    EXPECT(d == VideoDelivery::Malformed && !accepted(d));

    // Stale generation and an invalidated inbox: accepted for Chiaki, nothing queued.
    inbox.invalidate();
    d = deliver(SampleKind::AccessUnit, idr(), frame++);
    EXPECT(d == VideoDelivery::Discarded && accepted(d));
    inbox.finishStop();
    auto next = inbox.begin(monotonic100ns());
    d = deliver(SampleKind::AccessUnit, idr(), frame++); // old token
    EXPECT(d == VideoDelivery::Discarded && accepted(d));
    inbox.invalidate();
    inbox.finishStop();
    (void)next;
}

// ---- Regression (Framelift: ported from 86383c70): the owner samples its clock before
// SessionInbox::tryVideo takes the lock. A frame chiaki stamps and queues in between carries a later
// stamp; it must be handed out, not taken for expired (which emptied the queue until the next IDR).
void regressionReaderClockBehind() {
    std::mt19937 rng(43);
    std::vector<uint8_t> config;
    for (uint8_t t : {32, 33, 34}) {
        auto n = nal({uint8_t(t << 1), 1}, rng, 8);
        config.insert(config.end(), n.begin(), n.end());
    }
    QueueLimits limits;
    SessionInbox inbox(limits);
    auto token = inbox.begin(monotonic100ns());
    const auto readerNow = monotonic100ns() - 1; // the reader's sample, taken before the push
    EXPECT(deliverChiakiVideo(token, makeSample(token, SampleKind::CodecConfig, config)) == VideoDelivery::Queued);
    EXPECT(deliverChiakiVideo(token, makeSample(token, SampleKind::AccessUnit, nal({19 << 1, 1}, rng, 300), 0)) ==
           VideoDelivery::Queued);
    {
        auto unit = inbox.tryVideo(readerNow);
        EXPECT(unit && unit->sample.wireFrameIndex == 0);
        const auto v = inbox.snapshot().video;
        EXPECT(v.recoveries == 0 && !v.waitingForIdr);
    }
    // A frame that really waited longer than the limit still resets the queue.
    auto old = makeSample(token, SampleKind::AccessUnit, nal({1 << 1, 1}, rng, 120), 1);
    const auto stamped = old.arrival100ns;
    EXPECT(deliverChiakiVideo(token, std::move(old)) == VideoDelivery::Queued);
    EXPECT(!inbox.tryVideo(stamped + limits.maxAge100ns + 1));
    {
        const auto v = inbox.snapshot().video;
        EXPECT(v.recoveries == 1 && v.waitingForIdr);
    }
    inbox.invalidate();
    inbox.finishStop();
}

// ---- Controller order (ControllerOutbox / PushFPS ControllerQueue). The bridge owner drains the
// outbox once per loop and submits each state to chiaki in that order (Bridge.cpp). A press and a
// release within one owner tick must both come out, in order; sticks and motion must not queue.
void regressionControllerOrder() {
    using S = ControllerState;
    constexpr HostTime ms = 10000;
    const auto pad = [](std::uint32_t buttons, std::int16_t lx = 0, std::uint8_t l2 = 0) {
        S s;
        s.inputActive = true;
        s.buttons = buttons;
        s.leftX = lx;
        s.l2 = l2;
        return s;
    };
    std::vector<S> out;
    const HostTime t0 = 1000 * ms;

    // Press and release between two owner reads, with stick motion around them.
    {
        ControllerOutbox q;
        EXPECT(q.push(pad(0, 10), t0));
        EXPECT(q.push(pad(S::Cross, 20), t0 + 1));
        EXPECT(q.push(pad(S::Cross, 30), t0 + 2));
        EXPECT(q.push(pad(0, 40), t0 + 3));
        q.drain(t0 + 4, out);
        EXPECT(out.size() == 3);
        EXPECT(out.size() == 3 && out[0].buttons == 0 && out[1].buttons == S::Cross && out[1].leftX == 30 &&
               out[2].buttons == 0 && out[2].leftX == 40);
        out.clear();
        q.drain(t0 + 5, out);
        EXPECT(out.empty()); // nothing waits: the owner submits nothing new
    }
    // A quick double tap and a chord, all within one tick: every edge, in order.
    {
        ControllerOutbox q;
        const std::uint32_t order[] = {S::Square, 0, S::Square, S::Square | S::R1, S::R1, 0};
        HostTime t = t0;
        for (auto b : order) EXPECT(q.push(pad(b), t++));
        q.drain(t, out);
        EXPECT(out.size() == 6);
        for (std::size_t i = 0; i < out.size() && i < 6; ++i) EXPECT(out[i].buttons == order[i]);
        out.clear();
    }
    // A short L2 pull across trigger bands is not collapsed to its last faint value.
    {
        ControllerOutbox q;
        EXPECT(q.push(pad(0, 0, 0), t0));
        EXPECT(q.push(pad(0, 0, 200), t0 + 1));
        EXPECT(q.push(pad(0, 0, 30), t0 + 2));
        q.drain(t0 + 3, out);
        EXPECT(out.size() == 3 && out[1].l2 == 200 && out[2].l2 == 30);
        out.clear();
    }
    // Sticks only: they coalesce into one state with the newest values.
    {
        ControllerOutbox q;
        for (int i = 0; i < 50; ++i) EXPECT(q.push(pad(S::L1, std::int16_t(i * 100)), t0 + i));
        EXPECT(q.pending() == 1);
        q.drain(t0 + 60, out);
        EXPECT(out.size() == 1 && out[0].leftX == 4900 && out[0].buttons == S::L1);
        out.clear();
    }
    // Motion: every IMU sample once, in order, also when an edge splits the batch.
    {
        ControllerOutbox q;
        for (int i = 0; i < 10; ++i) {
            S s = pad(i < 5 ? 0 : S::Cross);
            s.motionValid = true;
            s.motionTimestampUs = 1000 + std::uint64_t(i) * 1000;
            s.gyro = {float(i), 0, 0};
            EXPECT(q.push(s, t0 + i));
            if (i == 7) EXPECT(q.push(s, t0 + i)); // repeated sample (button event without new IMU)
        }
        q.drain(t0 + 20, out);
        EXPECT(out.size() == 2);
        std::vector<std::uint64_t> stamps;
        for (const auto& s : out)
            for (std::size_t i = 0; i < s.motionSampleCount; ++i) stamps.push_back(s.motionSamples[i].timestampUs);
        EXPECT(stamps.size() == 10);
        for (std::size_t i = 0; i < stamps.size(); ++i) EXPECT(stamps[i] == 1000 + i * 1000);
        out.clear();
    }
    // Bounded: a mash of edges never holds more than kMaxPending, then fails safe.
    {
        ControllerOutbox q;
        bool fitted = true;
        for (int i = 0; i < 100; ++i) fitted = q.push(pad(i % 2 ? S::Cross : 0), t0 + i) && fitted;
        EXPECT(!fitted && q.pending() <= ControllerQueue::kMaxPending && q.stats().overflows >= 1);
        q.drain(t0 + 100, out);
        EXPECT(!out.empty() && out.size() <= ControllerQueue::kMaxPending);
        EXPECT(!out.empty() && out.back().buttons == S::Cross); // ends at the newest truth
        out.clear();
    }
}

void regressionRedaction() {
    auto keeps = [](const char* line) {
        std::string out;
        return framelift::redactLogLine(line, out);
    };
    // The leaked line: last row of chiaki_log_hexdump (offset 0x10, one byte 0x64, ASCII "d").
    EXPECT(!keeps("    10 64                                              d               "));
    EXPECT(!keeps("     0 10 64 00 01 a3 ff                                .d....          "));
    EXPECT(!keeps("     0 10 64                                            .d"));
    EXPECT(!keeps("    20 de ad be ef"));
    EXPECT(!keeps("10 64"));
    EXPECT(!keeps("1064"));
    EXPECT(!keeps("ab cd ef"));
    EXPECT(!keeps("offset 0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f  0123456789abcdef"));
    // Ordinary upstream lines survive.
    EXPECT(keeps("Received presumably invalid Session Id:"));
    EXPECT(keeps("Received Session Id is too short"));
    EXPECT(keeps("Detected missing or corrupt frame(s) from 2 to 3"));
    EXPECT(keeps("StreamConnection reporting corrupt frame(s) from 12 to 12"));
    EXPECT(keeps("Missing reference frame 12 for decoding frame 13"));
    EXPECT(keeps("Video callback did not process frame successfully."));
    EXPECT(keeps("FEC failed"));
    EXPECT(keeps("FEC successful"));
    EXPECT(keeps("Received IDR frame, resuming decode"));

    // Continuation rule: rows after a "...:" intro are dropped until the first normal line.
    framelift::LogRedactor r;
    std::string out;
    EXPECT(r.redact("Received presumably invalid Session Id:", out));
    EXPECT(!r.redact("offset 0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f  0123456789abcdef", out));
    EXPECT(!r.redact("     0 10 64 00 01 a3 ff 7f 22 9c 41 0b 6e 5d 13 c8 2a  .d....\"A.n].*", out));
    EXPECT(!r.redact("    10 64                                              d               ", out));
    EXPECT(!r.redact("    indented continuation without hex", out));
    EXPECT(r.redact("Received Session Id is too short", out) && out == "Received Session Id is too short");
    EXPECT(r.redact("    a normal line after the dump ended", out)); // state disarmed
    EXPECT(r.redact("Detected missing or corrupt frame(s) from 2 to 3", out));
}

void producer(unsigned seed) {
    std::mt19937 rng(seed);
    uint64_t sample = 0;
    while (running) {
        std::optional<SessionInbox::Token> token;
        {
            std::lock_guard lock(tokenMutex);
            token = (rng() % 8 == 0 && staleToken) ? staleToken : currentToken;
        }
        if (!token) continue;
        const auto roll = rng() % 100;
        VideoSample s;
        s.generation = token->generation();
        s.codec = Codec::H265;
        s.width = 1920;
        s.height = 1080;
        s.arrival100ns = monotonic100ns();
        std::vector<uint8_t> bytes;
        if (roll < 5) { // config: VPS+SPS+PPS
            s.kind = SampleKind::CodecConfig;
            for (uint8_t t : {32, 33, 34}) {
                auto n = nal({uint8_t(t << 1), 1}, rng, 8);
                bytes.insert(bytes.end(), n.begin(), n.end());
            }
        } else if (roll < 12) { // IDR
            bytes = nal({19 << 1, 1}, rng, 200 + rng() % 2000);
        } else if (roll < 90) { // P frame, sometimes with loss/recovery metadata
            bytes = nal({1 << 1, 1}, rng, 50 + rng() % 4000);
            if (rng() % 50 == 0) s.framesLost = 1 + int(rng() % 3);
            if (rng() % 80 == 0) s.referenceRecovered = true;
        } else if (roll < 95) { // corrupt / truncated
            bytes.resize(rng() % 64);
            for (auto& b : bytes) b = uint8_t(rng());
        } else { // events
            switch (rng() % 4) {
            case 0: token->connected(); break;
            case 1: token->loginPinRequired(); break;
            case 2: if (rng() % 20 == 0) token->failed(2000 + int(rng() % 14)); break;
            default: token->wake(); break;
            }
            continue;
        }
        if (bytes.empty()) bytes.push_back(0);
        s.payload = PaddedBytes::copy(bytes);
        ++produced;
        if (token->video(std::move(s))) ++accepted;
        if (rng() % 3 == 0) {
            PcmBlock b;
            b.generation = token->generation();
            b.channels = 2;
            b.rate = 48000;
            b.firstSample = sample;
            b.arrival100ns = monotonic100ns();
            b.samples.assign(480 * 2, int16_t(rng()));
            sample += 480;
            (void)token->audio(std::move(b));
        }
        if (rng() % 64 == 0) std::this_thread::yield();
    }
}

void consumer(SessionInbox& inbox) {
    std::mt19937 rng(99);
    while (running) {
        {
            std::unique_lock lock(wakeMutex);
            wakeCv.wait_for(lock, std::chrono::milliseconds(1), [] { return woken || !running; });
            woken = false;
        }
        while (auto unit = inbox.tryVideo(monotonic100ns())) {
            ++consumedVideo;
            if (unit->resetDecoder && !unit->configBefore) ++violations;
            if (!unit->sample.payload.paddingIsZero()) ++violations;
        }
        while (auto block = inbox.tryAudio()) {
            ++consumedAudio;
            if (!block->valid()) ++violations;
        }
        (void)inbox.takeIdrRequest(monotonic100ns());
        if (rng() % 200 == 0) inbox.decodeFailed(inbox.snapshot().generation);
        (void)inbox.status();
    }
}
} // namespace

int main(int argc, char** argv) {
    const int seconds = argc > 1 ? std::atoi(argv[1]) : 10;
    regressionVideoCallback();
    regressionReaderClockBehind();
    regressionControllerOrder();
    regressionRedaction();
    if (regressionFailures) {
        std::fprintf(stderr, "regression: %d failure(s)\n", regressionFailures);
        return 4;
    }
    std::printf("regression: video callback + reader clock + controller order + log redaction OK\n");
    QueueLimits limits;
    SessionInbox inbox(limits);
    inbox.setWakeHook(&onWake, nullptr);
    {
        std::lock_guard lock(tokenMutex);
        currentToken = inbox.begin(monotonic100ns());
    }
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < 3; ++i) threads.emplace_back(producer, 1234 + i);
    threads.emplace_back(consumer, std::ref(inbox));
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    std::mt19937 rng(7);
    uint64_t generations = 1;
    while (std::chrono::steady_clock::now() < end) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20 + rng() % 200));
        // Generation change in the documented order. Producers may still hold the old token:
        // its calls must be rejected as stale (weak ownership + generation check).
        inbox.invalidate();
        inbox.finishStop();
        auto next = inbox.begin(monotonic100ns());
        std::lock_guard lock(tokenMutex);
        staleToken = currentToken;
        currentToken = next;
        ++generations;
    }
    running = false;
    wakeCv.notify_all();
    for (auto& t : threads) t.join();
    inbox.invalidate();
    const auto snap = inbox.snapshot();
    std::printf("stress %ds: generations=%llu produced=%llu accepted=%llu video_out=%llu audio_out=%llu wakes=%llu "
                "stale_callbacks=%llu violations=%llu\n",
                seconds, (unsigned long long)generations, (unsigned long long)produced.load(),
                (unsigned long long)accepted.load(), (unsigned long long)consumedVideo.load(),
                (unsigned long long)consumedAudio.load(), (unsigned long long)wakes.load(),
                (unsigned long long)snap.staleCallbacks, (unsigned long long)violations.load());
    return violations.load() ? 3 : 0;
}
