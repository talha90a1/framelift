// SPDX-License-Identifier: GPL-3.0-only
// C ABI (VeyraBridge.h) over ChiakiBackend + SessionInbox + VideoIngress.
// Uses chiaki-ng's AGPL-3.0-only + OpenSSL-exception APIs; retain both licenses.
// Threading: one owner thread per session calls every backend method and the C callbacks; Chiaki
// threads and vr_session_* calls only post into the inbox/commands and wake it.
// Credentials live in PairingCredentials (wiped on destruction) and are never logged.
#include "VeyraBridge.h"
#include "ControllerOutbox.h"
#include "LogRedaction.h"
#include "veyra/remoteplay/ChiakiBackend.h"
#include "veyra/remoteplay/Discovery.h"
#include "veyra/remoteplay/SessionInbox.h"
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

using namespace veyra::remoteplay;

namespace {
enum : int32_t {
    kErrInvalidArgument = -2001,
    kErrInternal = -2002,
    kErrNoSession = -2003,
};
// A Chiaki QUIT is reported by Veyra's backend as token.failed(2000 + reason).
constexpr int kQuitBase = 2000;
constexpr int kQuitReasonMax = 13; // CHIAKI_QUIT_REASON_PSN_REGIST_FAILED
// Backstop only: media, events and feedback all wake the owner immediately.
constexpr auto kIdleWait = std::chrono::milliseconds(1);
constexpr HostTime kStatsInterval100ns = 1000000; // 100 ms

void wipe(void* ptr, std::size_t n) noexcept {
    auto* p = static_cast<volatile unsigned char*>(ptr);
    while (n--) *p++ = 0;
}

uint64_t hostTimeFromArrival(HostTime arrival100ns) noexcept {
    static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info{};
        mach_timebase_info(&info);
        return info;
    }();
    const auto nowMach = mach_absolute_time();
    const auto age100ns = std::max<HostTime>(0, monotonic100ns() - arrival100ns);
    const auto ageTicks = static_cast<uint64_t>(
        static_cast<long double>(age100ns) * 100.0L * timebase.denom / timebase.numer);
    return ageTicks < nowMach ? nowMach - ageTicks : 0;
}

ControllerState toVeyra(const VRControllerState& in) {
    ControllerState out;
    out.inputActive = true;
    out.buttons = in.buttons & 0xffffu;
    out.leftX = in.left_x; out.leftY = in.left_y; out.rightX = in.right_x; out.rightY = in.right_y;
    out.l2 = in.l2; out.r2 = in.r2;
    for (std::size_t i = 0; i < out.touches.size(); ++i) {
        out.touches[i].id = in.touches[i].id;
        out.touches[i].x = std::min<uint16_t>(in.touches[i].x, 1919);
        out.touches[i].y = std::min<uint16_t>(in.touches[i].y, 1079);
    }
    out.motionValid = in.motion_valid;
    std::copy_n(in.gyro, 3, out.gyro.begin());
    std::copy_n(in.accel, 3, out.accel.begin());
    out.motionTimestampUs = in.motion_timestamp_us;
    return out;
}

Codec toVeyra(VRCodec codec) {
    switch (codec) {
    case VR_CODEC_H264: return Codec::H264;
    case VR_CODEC_H265: return Codec::H265;
    case VR_CODEC_H265_HDR: return Codec::H265Hdr;
    }
    return Codec::H264;
}

int32_t errorFrom(const BackendResult& r) noexcept {
    if (r.ok) return 0;
    return r.code != 0 ? r.code : kErrInternal;
}

// Fixed-size window of latency samples (owner thread only).
class LatencyWindow {
public:
    void add(double ms) noexcept {
        samples_[next_] = ms;
        next_ = (next_ + 1) % samples_.size();
        count_ = std::min(count_ + 1, samples_.size());
    }
    // {p50, p99, max}
    std::array<double, 3> summary() const {
        if (!count_) return {0, 0, 0};
        std::vector<double> sorted(samples_.begin(), samples_.begin() + static_cast<std::ptrdiff_t>(count_));
        std::sort(sorted.begin(), sorted.end());
        const auto at = [&](double q) { return sorted[std::min(sorted.size() - 1, static_cast<std::size_t>(q * (sorted.size() - 1) + 0.5))]; };
        return {at(0.5), at(0.99), sorted.back()};
    }

private:
    std::array<double, 256> samples_{};
    std::size_t next_ = 0, count_ = 0;
};

double ms100ns(HostTime from, HostTime to) noexcept { return to >= from ? double(to - from) / 10000.0 : 0.0; }

// Process-wide chiaki log forwarding (vr_set_log_callback). The mutex is held while calling the
// app so that after vr_set_log_callback(NULL) returns no call is in flight.
struct LogSink {
    std::mutex mutex;
    VRLogCallback callback = nullptr;
    void* user = nullptr;
    uint32_t mask = VR_LOG_WARNING | VR_LOG_ERROR;
};
LogSink& logSink() {
    static LogSink sink;
    return sink;
}
void forwardRedacted(int level, const char* line) noexcept {
    try {
        // One redactor per Chiaki thread: a hexdump's rows come from the thread that logged its
        // "...:" intro line, and other threads' lines must not end that continuation state.
        // Runs before the level mask so the state also tracks lines the app does not receive.
        thread_local framelift::LogRedactor redactor;
        std::string clean;
        const bool keep = line && redactor.redact(line, clean);
        auto& sink = logSink();
        std::lock_guard lock(sink.mutex);
        if (!keep || !sink.callback || !(sink.mask & static_cast<uint32_t>(level))) return;
        sink.callback(sink.user, level, clean.c_str());
    } catch (...) {
    }
}

template <std::size_t N> void copyString(char (&out)[N], const std::string& in) noexcept {
    const auto n = std::min(in.size(), N - 1);
    std::memcpy(out, in.data(), n);
    out[n] = '\0';
}
} // namespace

struct VRSession {
    VRCallbacks callbacks{};
    std::string host;
    VideoProfile profile;
    PairingCredentials credentials; // moved into the connect request on the owner thread
    std::thread owner;

    // Command/wake state. Never held while calling the inbox, the backend or a C callback.
    std::mutex mutex;
    std::condition_variable cv;
    bool woken = false, stopRequested = false;
    bool startDone = false;
    int32_t startError = 0;
    ControllerOutbox controllers;
    bool hasPin = false;
    std::array<char, 9> pin{};
    bool idrRequested = false;

    // Telemetry published by the owner thread.
    std::mutex statsMutex;
    VRStats stats{};
    VRDiagnostics diagnostics{};
    bool leaked = false; // backend join failed: memory may still be referenced by Chiaki threads

    static void wakeHook(void* user) noexcept {
        auto& self = *static_cast<VRSession*>(user);
        {
            std::lock_guard lock(self.mutex);
            self.woken = true;
        }
        self.cv.notify_one();
    }

    void run() noexcept;
    void emitEvent(VREventType type, int32_t code, int32_t a = 0, int32_t b = 0) const noexcept {
        if (callbacks.event) callbacks.event(callbacks.user, type, code, a, b);
    }
    void finishStart(int32_t error) {
        {
            std::lock_guard lock(mutex);
            startDone = true;
            startError = error;
        }
        cv.notify_all();
    }
};

void VRSession::run() noexcept {
    // Session owner/delivery thread: it hands every video unit, audio block and feedback event to
    // the app, so it runs at user-interactive QoS (chiaki's own threads get it via patch 0100).
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    bool started = false;
    try {
        SessionInbox inbox;
        inbox.setWakeHook(&VRSession::wakeHook, this);
        ChiakiBackend backend;
        auto token = inbox.begin(monotonic100ns());
        const auto generation = token.generation();
        NativeConnectRequest request;
        request.host = host;
        request.video = profile;
        request.credentials = std::move(credentials);
        const auto startResult = backend.start(request, std::move(token));
        request.credentials = PairingCredentials{}; // wipe the copy now that chiaki has it
        if (!startResult.ok) {
            inbox.invalidate();
            if (backend.stop().ok) inbox.finishStop();
            finishStart(errorFrom(startResult));
            return;
        }
        started = true;
        finishStart(0);

        uint64_t videoUnits = 0, configUnits = 0, audioBlocks = 0, idrSent = 0, wakeups = 0, idleTimeouts = 0;
        LatencyWindow videoQueueLatency, audioQueueLatency, videoCallbackTime;
        uint64_t pinEventsSeen = 0;
        bool connectedSent = false, terminalSent = false;
        HostTime lastStats = 0;
        std::vector<ControllerState> controllerBatch;
        controllerBatch.reserve(ControllerQueue::kMaxPending + 1);

        for (;;) {
            bool stop = false, idr = false, havePin = false;
            std::array<char, 9> pinCopy{};
            controllerBatch.clear();
            {
                std::unique_lock lock(mutex);
                if (cv.wait_for(lock, kIdleWait, [&] { return woken || stopRequested; })) ++wakeups;
                else ++idleTimeouts;
                woken = false;
                stop = stopRequested;
                idr = std::exchange(idrRequested, false);
                if (hasPin) {
                    havePin = true;
                    pinCopy = pin;
                    wipe(pin.data(), pin.size());
                    hasPin = false;
                }
                // Every waiting state, oldest first: a press and a release that both arrived since
                // the last read each reach chiaki (which records each change in its button history).
                controllers.drain(monotonic100ns(), controllerBatch);
            }
            if (stop) break;

            const auto status = inbox.status();
            const bool live = status.state != SessionState::Failed;
            if (havePin && live) {
                const auto length = static_cast<std::size_t>(
                    std::find(pinCopy.begin(), pinCopy.end(), '\0') - pinCopy.begin());
                (void)backend.submitLoginPin(std::string_view(pinCopy.data(), length));
            }
            wipe(pinCopy.data(), pinCopy.size());
            if (live)
                for (const auto& state : controllerBatch) (void)backend.submitController(state);
            // Only arm the (rate-limited) console IDR request; do not gate the ingress, the decoder
            // already drops non-IDR units until a clean IDR.
            if (idr) inbox.requestIdr(generation);

            while (auto unit = inbox.tryVideo(monotonic100ns())) {
                const auto& sample = unit->sample;
                const auto popped = monotonic100ns();
                videoQueueLatency.add(ms100ns(sample.arrival100ns, popped));
                if (callbacks.video) {
                    if (unit->configBefore) {
                        const auto& config = *unit->configBefore;
                        // recovered=false: the config is not a recovery point; the IDR right after it
                        // carries resetDecoder.
                        callbacks.video(callbacks.user, config.payload.data(), config.payload.size(), true,
                                        config.width, config.height, 0, false,
                                        hostTimeFromArrival(config.arrival100ns));
                        ++configUnits;
                    }
                    callbacks.video(callbacks.user, sample.payload.data(), sample.payload.size(), false,
                                    sample.width, sample.height, sample.framesLost,
                                    unit->resetDecoder || sample.referenceRecovered,
                                    hostTimeFromArrival(sample.arrival100ns));
                    videoCallbackTime.add(ms100ns(popped, monotonic100ns()));
                }
                ++videoUnits;
            }
            while (auto block = inbox.tryAudio()) {
                audioQueueLatency.add(ms100ns(block->arrival100ns, monotonic100ns()));
                if (callbacks.audio && block->channels)
                    callbacks.audio(callbacks.user, block->samples.data(), block->frames(), block->channels,
                                    block->rate);
                ++audioBlocks;
            }
            // Veyra's ingress rate-limits IDR requests (500 ms) while it waits for a clean keyframe.
            if (inbox.takeIdrRequest(monotonic100ns()) && backend.requestIdr().ok) ++idrSent;

            // Feedback (rumble, adaptive triggers, haptics, motion reset).
            auto feedback = backend.takeFeedback();
            if (feedback.rumble) emitEvent(VR_EVENT_RUMBLE, 0, feedback.left, feedback.right);
            if (feedback.triggers && callbacks.triggers)
                callbacks.triggers(callbacks.user, feedback.leftTrigger[0], feedback.leftTrigger.data() + 1,
                                   feedback.rightTrigger[0], feedback.rightTrigger.data() + 1);
            if (!feedback.haptics.empty() && callbacks.haptics)
                callbacks.haptics(callbacks.user, feedback.haptics.data(), feedback.haptics.size() / 2);
            if (feedback.motionReset) emitEvent(VR_EVENT_MOTION_RESET, 0);

            const auto after = inbox.status();
            if (after.loginPinRequests > pinEventsSeen) {
                pinEventsSeen = after.loginPinRequests;
                emitEvent(VR_EVENT_LOGIN_PIN_REQUEST, 0);
            }
            if (!connectedSent &&
                (after.state == SessionState::WaitingFirstFrame || after.state == SessionState::Streaming)) {
                connectedSent = true;
                emitEvent(VR_EVENT_CONNECTED, 0);
            }
            if (!terminalSent && after.state == SessionState::Failed) {
                terminalSent = true;
                const int code = after.errorCode;
                if (code >= kQuitBase && code <= kQuitBase + kQuitReasonMax)
                    emitEvent(VR_EVENT_QUIT, code - kQuitBase);
                else
                    emitEvent(VR_EVENT_FAILED, code != 0 ? code : kErrInternal);
            }

            const auto now = monotonic100ns();
            if (now - lastStats >= kStatsInterval100ns) {
                lastStats = now;
                const auto native = backend.snapshot();
                const auto inboxSnapshot = inbox.snapshot();
                const auto& video = inboxSnapshot.video;
                const auto& audio = inboxSnapshot.audio;
                VRDiagnostics d{};
                d.valid = true;
                d.session_state = static_cast<int32_t>(inboxSnapshot.state);
                d.inbox_error = inboxSnapshot.errorCode;
                d.last_quit_reason = native.lastQuitReason;
                d.last_api_error = native.lastApiError;
                d.video_access_units = video.accessUnits;
                d.video_config_messages = video.configMessages;
                d.video_accepted = video.accepted;
                d.video_consumed = video.consumed;
                d.video_dropped = video.dropped;
                d.video_rejected = video.rejected;
                d.video_recoveries = video.recoveries;
                d.video_idr_requests = video.idrRequests;
                d.video_epoch = video.epoch;
                d.video_depth = static_cast<uint32_t>(video.depth);
                d.video_high_water_depth = static_cast<uint32_t>(video.highWaterDepth);
                d.video_bytes_queued = video.bytes;
                d.video_high_water_bytes = video.highWaterBytes;
                d.video_waiting_for_idr = video.waitingForIdr;
                d.audio_accepted = audio.accepted;
                d.audio_consumed = audio.consumed;
                d.audio_dropped = audio.dropped;
                d.audio_rejected = audio.rejected;
                d.audio_buffered_ms = audio.bufferedMs;
                d.stale_callbacks = inboxSnapshot.staleCallbacks;
                d.inbox_received_bytes = inboxSnapshot.receivedBytes;
                d.inbox_frames_lost = inboxSnapshot.framesLost;
                d.inbox_reference_recoveries = inboxSnapshot.referenceRecoveryEvents;
                d.received_fps = inboxSnapshot.receivedFps; // inbox window is 1 s (10^7 x 100 ns)
                d.video_mbps = inboxSnapshot.videoMbps;
                d.chiaki_video_callbacks = native.videoCallbacks;
                d.chiaki_audio_callbacks = native.audioCallbacks;
                d.callback_rejected = native.callbackRejected;
                d.packets_received = native.packetReceived;
                d.packets_lost = native.packetLost;
                d.log_warnings = native.warnings;
                d.log_errors = native.errors;
                d.log_infos = native.infos;
                d.transport_errors = native.transportErrors;
                d.assembly_errors = native.assemblyErrors;
                d.fec_success = native.fecSuccess;
                d.fec_failed = native.fecFailed;
                d.idr_retries = native.idrRetries;
                d.missing_reference_frames = native.missingReferenceFrames;
                d.corrupt_frame_reports = native.corruptFrameReports;
                d.metadata_frames_lost = native.metadataFramesLost;
                d.metadata_recovered_frames = native.metadataRecoveredFrames;
                d.chiaki_video_bytes = native.videoBytes;
                d.server_target_bitrate = native.serverTargetBitrate;
                d.quality_reports = native.qualityReports;
                d.delivered_video_units = videoUnits;
                d.delivered_config_units = configUnits;
                d.delivered_audio_blocks = audioBlocks;
                d.idr_sent = idrSent;
                const auto vq = videoQueueLatency.summary();
                const auto aq = audioQueueLatency.summary();
                const auto vc = videoCallbackTime.summary();
                d.video_queue_latency_ms_p50 = vq[0];
                d.video_queue_latency_ms_p99 = vq[1];
                d.video_queue_latency_ms_max = vq[2];
                d.audio_queue_latency_ms_p50 = aq[0];
                d.audio_queue_latency_ms_p99 = aq[1];
                d.video_callback_ms_p50 = vc[0];
                d.video_callback_ms_p99 = vc[1];
                d.owner_wakeups = wakeups;
                d.owner_idle_timeouts = idleTimeouts;
                d.takion_version = native.takionVersion;
                d.takion_v20_offered = native.takionV20Offered;
                d.packets_received_total = native.packetReceivedTotal;
                d.packets_lost_total = native.packetLostTotal;
                d.audio_source_channels = native.audioSourceChannels;
                VRStats next{};
                next.connected = native.connected;
                next.video_units = videoUnits;
                next.audio_blocks = audioBlocks;
                next.packets_received = native.packetReceived;
                next.packets_lost = native.packetLost;
                next.warnings = native.warnings;
                next.errors = native.errors;
                next.idr_requests = std::max<uint64_t>(idrSent, video.idrRequests);
                next.last_quit_reason = native.lastQuitReason;
                next.server_target_bitrate = native.serverTargetBitrate;
                std::lock_guard lock(statsMutex);
                stats = next;
                diagnostics = d;
            }
        }

        // Veyra's required order: invalidate (stale callbacks rejected), stop+join Chiaki, finishStop.
        inbox.invalidate();
        const auto stopped = backend.stop();
        if (stopped.ok) {
            inbox.finishStop();
        } else {
            // Chiaki threads may still reference this session; ~ChiakiBackend quarantines itself.
            std::lock_guard lock(mutex);
            leaked = true;
        }
        std::lock_guard lock(statsMutex);
        stats.connected = false;
    } catch (...) {
        if (!started) finishStart(kErrInternal);
        else emitEvent(VR_EVENT_FAILED, kErrInternal);
    }
}

extern "C" {

int32_t vr_init(void) {
    try {
        return errorFrom(initializeChiaki());
    } catch (...) {
        return kErrInternal;
    }
}

VRSession* vr_session_start(const char* host, const VRCredentials* credentials, const VRVideoProfile* profile,
                            const VRCallbacks* callbacks, int32_t* error_out) {
    auto fail = [&](int32_t code) -> VRSession* {
        if (error_out) *error_out = code;
        return nullptr;
    };
    if (!host || !credentials || !profile || !callbacks) return fail(kErrInvalidArgument);
    try {
        VideoProfile video;
        video.width = profile->width;
        video.height = profile->height;
        video.fps = profile->fps;
        video.bitrateKbps = profile->bitrate_kbps;
        video.codec = toVeyra(profile->codec);
        if (video.validate() || !validHost(host)) return fail(kErrInvalidArgument);

        auto session = std::make_unique<VRSession>();
        session->callbacks = *callbacks;
        session->host = host;
        session->profile = video;
        std::memcpy(session->credentials.accountId.data(), credentials->account_id, 8);
        std::memcpy(session->credentials.registrationKey.data(), credentials->regist_key, 16);
        std::memcpy(session->credentials.sessionKey.data(), credentials->morning, 16);

        auto* raw = session.get();
        raw->owner = std::thread([raw] { raw->run(); });
        int32_t error = 0;
        {
            std::unique_lock lock(raw->mutex);
            raw->cv.wait(lock, [&] { return raw->startDone; });
            error = raw->startError;
        }
        if (error != 0) {
            raw->owner.join();
            if (raw->leaked) (void)session.release();
            return fail(error);
        }
        if (error_out) *error_out = 0;
        return session.release();
    } catch (...) {
        return fail(kErrInternal);
    }
}

void vr_session_stop(VRSession* session) {
    if (!session) return;
    {
        std::lock_guard lock(session->mutex);
        session->stopRequested = true;
    }
    session->cv.notify_all();
    if (session->owner.joinable()) session->owner.join();
    bool leaked = false;
    {
        std::lock_guard lock(session->mutex);
        leaked = session->leaked;
    }
    if (!leaked) delete session; // else: quarantined, Chiaki threads may still reference it
}

int32_t vr_session_request_idr(VRSession* session) {
    if (!session) return kErrNoSession;
    {
        std::lock_guard lock(session->mutex);
        session->idrRequested = true;
        session->woken = true;
    }
    session->cv.notify_one();
    return 0;
}

int32_t vr_session_set_controller(VRSession* session, const VRControllerState* state) {
    if (!session) return kErrNoSession;
    if (!state) return kErrInvalidArgument;
    try {
        auto next = toVeyra(*state);
        {
            std::lock_guard lock(session->mutex);
            // Edges queue in order, levels merge into the newest waiting state, and every IMU
            // sample is kept once so the orientation tracker integrates each of them.
            (void)session->controllers.push(std::move(next), monotonic100ns());
            session->woken = true;
        }
        session->cv.notify_one();
        return 0;
    } catch (...) {
        return kErrInternal;
    }
}

int32_t vr_session_set_login_pin(VRSession* session, const char* pin) {
    if (!session) return kErrNoSession;
    if (!pin) return kErrInvalidArgument;
    const auto length = std::strlen(pin);
    if (length == 0 || length > 8 || !std::all_of(pin, pin + length, [](char c) { return c >= '0' && c <= '9'; }))
        return kErrInvalidArgument;
    {
        std::lock_guard lock(session->mutex);
        session->pin.fill('\0');
        std::memcpy(session->pin.data(), pin, length);
        session->hasPin = true;
        session->woken = true;
    }
    session->cv.notify_one();
    return 0;
}

VRStats vr_session_stats(VRSession* session) {
    if (!session) return VRStats{};
    std::lock_guard lock(session->statsMutex);
    return session->stats;
}

VRDiagnostics vr_session_diagnostics(VRSession* session) {
    if (!session) return VRDiagnostics{};
    std::lock_guard lock(session->statsMutex);
    return session->diagnostics;
}

void vr_set_log_callback(VRLogCallback callback, void* user, uint32_t level_mask) {
    auto& sink = logSink();
    {
        std::lock_guard lock(sink.mutex);
        sink.callback = callback;
        sink.user = user;
        sink.mask = level_mask ? level_mask : (VR_LOG_WARNING | VR_LOG_ERROR);
    }
    setChiakiLogForwarder(callback ? &forwardRedacted : nullptr, callback ? level_mask : 0);
}

VRPairResult vr_pair_ps5(const char* host, const uint8_t account_id[8], const char* pin, uint32_t timeout_ms) {
    VRPairResult out{};
    if (!host || !account_id || !pin) {
        out.error = kErrInvalidArgument;
        return out;
    }
    try {
        AccountId account{};
        std::memcpy(account.data(), account_id, account.size());
        const auto timeout = std::chrono::milliseconds(std::clamp<uint32_t>(timeout_ms, 1000, 60000));
        auto result = pairLocalPs5(host, account, pin, {}, timeout);
        wipe(account.data(), account.size());
        out.error = errorFrom(result.result);
        if (out.error != 0) { copyString(out.detail, result.detail); return out; }
        std::memcpy(out.credentials.account_id, result.credentials.accountId.data(), 8);
        std::memcpy(out.credentials.regist_key, result.credentials.registrationKey.data(), 16);
        std::memcpy(out.credentials.morning, result.credentials.sessionKey.data(), 16);
        std::memcpy(out.console_mac, result.mac.data(), 6);
        copyString(out.nickname, result.nickname);
        return out; // result's PairingCredentials wipe themselves
    } catch (...) {
        wipe(&out, sizeof(out));
        out.error = kErrInternal;
        return out;
    }
}

int32_t vr_discover(VRDiscoveredHost* hosts, int32_t max, uint32_t timeout_ms) {
    if (!hosts || max <= 0) return kErrInvalidArgument;
    try {
        const auto timeout = std::chrono::milliseconds(std::clamp<uint32_t>(timeout_ms, 100, 30000));
        const auto report = discoverLocalConsoles({}, timeout, true);
        if (report.hosts.empty() && report.error != 0) return report.error < 0 ? report.error : -report.error;
        const auto count = std::min<std::size_t>(report.hosts.size(), static_cast<std::size_t>(max));
        for (std::size_t i = 0; i < count; ++i) {
            auto& out = hosts[i];
            std::memset(&out, 0, sizeof(out));
            const auto& in = report.hosts[i];
            copyString(out.address, in.host);
            copyString(out.host_id, in.consoleId);
            copyString(out.name, in.name);
            out.is_ps5 = in.isPs5;
            out.standby = in.standby;
        }
        return static_cast<int32_t>(count);
    } catch (...) {
        return kErrInternal;
    }
}

int32_t vr_wakeup(const char* host, const char regist_key[16]) {
    if (!host || !regist_key) return kErrInvalidArgument;
    try {
        NativeConnectRequest request;
        request.host = host;
        std::memcpy(request.credentials.registrationKey.data(), regist_key, 16);
        return errorFrom(wakeLocalPs5(request));
    } catch (...) {
        return kErrInternal;
    }
}

} // extern "C"
