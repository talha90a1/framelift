// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "VideoIngress.h"
#include <memory>
#include <stdexcept>
namespace veyra::remoteplay {
// Thread-safe callback boundary, NOT a replacement Remote Play protocol/session.
// Invalidate before stopping Chiaki, join all its callbacks, then finishStop().
// Tokens hold weak ownership so a saved callback cannot resurrect a destroyed inbox.
class SessionInbox {
    struct Shared;
public:
    struct Snapshot {
        Generation generation=0;SessionState state=SessionState::Idle;
        std::uint64_t staleCallbacks=0;int errorCode=0;
        VideoQueueStats video;AudioQueueStats audio;
        uint64_t receivedBytes=0,framesLost=0,referenceRecoveryEvents=0;
        double receivedFps=0,videoMbps=0;
    };
    class Token {
    public:
        bool video(VideoSample sample) const noexcept;
        bool audio(PcmBlock block) const noexcept;
        void connected() const noexcept;
        void loginPinRequired() const noexcept;
        void failed(int code) const noexcept;
        // Framelift: wake the session owner (feedback arrived). No-op without a hook.
        void wake() const noexcept;
        Generation generation()const noexcept{return generation_;}
    private:
        friend class SessionInbox;Token(std::weak_ptr<Shared> shared,Generation g):shared_(std::move(shared)),generation_(g){}
        std::weak_ptr<Shared> shared_;Generation generation_=0;
    };
    // Framelift addition: called outside the inbox lock after every token delivery/state
    // change. Set only while Idle (before begin()); must not block.
    using WakeHook=void(*)(void* user) noexcept;
    void setWakeHook(WakeHook hook,void* user);
    // Cheap state read (no rate aggregation, unlike snapshot()). loginPinRequests
    // counts every upstream PIN request so a repeated request (wrong PIN) is visible.
    struct Status {SessionState state=SessionState::Idle;int errorCode=0;std::uint64_t loginPinRequests=0;};
    Status status()const;
    explicit SessionInbox(QueueLimits limits={});
    ~SessionInbox();
    SessionInbox(const SessionInbox&)=delete;SessionInbox& operator=(const SessionInbox&)=delete;
    Token begin(HostTime commonOrigin);
    void invalidate();
    void finishStop(); // Only after actual backend stop/join, not from a callback.
    std::optional<QueuedVideo> tryVideo(HostTime now);
    std::optional<PcmBlock> tryAudio();
    bool takeIdrRequest(HostTime now);
    void decodeFailed(Generation); // Gates the ingress until an IDR (internal recovery).
    // Framelift: the app's decoder asked for a keyframe. Arms the rate-limited
    // console IDR request only; the ingress keeps forwarding (the decoder gates itself).
    void requestIdr(Generation);
    Snapshot snapshot()const;
private:
    std::shared_ptr<Shared> shared_;
};
// Framelift: the decision behind Chiaki's video sample callback (chiaki-free so tests can call it).
// Return false ONLY for Malformed: Chiaki then drops the reference frame and every following P frame
// is reported corrupt until the next IDR. Discarded = well-formed but not queued.
enum class VideoDelivery {Queued,Discarded,Malformed};
VideoDelivery deliverChiakiVideo(const SessionInbox::Token&,VideoSample) noexcept;
inline bool chiakiVideoCallbackResult(VideoDelivery d) noexcept {return d!=VideoDelivery::Malformed;}
} // namespace veyra::remoteplay
