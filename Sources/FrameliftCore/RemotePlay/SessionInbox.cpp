// SPDX-License-Identifier: GPL-3.0-only
#include "framelift/remoteplay/SessionInbox.h"
#include <limits>
#include <algorithm>
namespace framelift::remoteplay {
struct SessionInbox::Shared {
    explicit Shared(QueueLimits limits):video(limits){}
    mutable std::mutex mutex;Generation generation=0;SessionState state=SessionState::Idle;
    bool accepting=false;std::uint64_t stale=0;int error=0;
    VideoIngress video;AudioIngress audio;
    uint64_t receivedBytes=0,framesLost=0,referenceRecoveryEvents=0;
    WakeHook wakeHook=nullptr;void* wakeUser=nullptr;std::uint64_t loginPinRequests=0;
    void wake() const noexcept {if(wakeHook)wakeHook(wakeUser);}
    struct Sample {HostTime time;double value;};
    std::deque<Sample> received;
    static void add(std::deque<Sample>& q,HostTime now,double value){
        while(!q.empty()&&(q.size()>=4096||q.front().time<=now-10000000))q.pop_front();q.push_back({now,value});
    }
    bool current(Generation g){if(!accepting||g!=generation){++stale;return false;}return true;}
};
SessionInbox::SessionInbox(QueueLimits l):shared_(std::make_shared<Shared>(l)){}
SessionInbox::~SessionInbox(){invalidate();}
SessionInbox::Token SessionInbox::begin(HostTime origin){
    if(origin<0)throw std::invalid_argument("Negative local clock origin");
    auto& s=*shared_;std::lock_guard lock(s.mutex);
    if(s.state!=SessionState::Idle)throw std::logic_error("Stop and join previous backend before a new session");
    if(s.generation==std::numeric_limits<Generation>::max())throw std::overflow_error("Session generation exhausted");
    ++s.generation;s.video.begin(s.generation);s.audio.begin(s.generation);s.state=SessionState::Connecting;s.accepting=true;s.error=0;
    s.receivedBytes=s.framesLost=s.referenceRecoveryEvents=0;s.loginPinRequests=0;
    s.received.clear();
    return Token{shared_,s.generation};
}
void SessionInbox::invalidate(){auto& s=*shared_;std::lock_guard l(s.mutex);s.accepting=false;if(s.state!=SessionState::Idle)s.state=SessionState::Stopping;s.video.close();s.audio.close();}
void SessionInbox::finishStop(){auto& s=*shared_;std::lock_guard l(s.mutex);if(s.accepting)throw std::logic_error("Invalidate before join/finishStop");s.state=SessionState::Idle;}
std::optional<QueuedVideo> SessionInbox::tryVideo(HostTime now){auto& s=*shared_;std::lock_guard l(s.mutex);if(!s.accepting)return {};return s.video.tryPop(now);}
std::optional<PcmBlock> SessionInbox::tryAudio(){auto& s=*shared_;std::lock_guard l(s.mutex);if(!s.accepting)return {};return s.audio.tryPop();}
bool SessionInbox::takeIdrRequest(HostTime now){auto& s=*shared_;std::lock_guard l(s.mutex);return s.accepting&&s.video.takeIdrRequest(now);}
void SessionInbox::decodeFailed(Generation g){auto& s=*shared_;std::lock_guard l(s.mutex);if(s.accepting&&s.generation==g)s.video.requireKeyframe();}
void SessionInbox::requestIdr(Generation g){auto& s=*shared_;std::lock_guard l(s.mutex);if(s.accepting&&s.generation==g)s.video.requestIdr();}
VideoDelivery deliverChiakiVideo(const SessionInbox::Token& token,VideoSample sample) noexcept{
    const auto bytes=sample.payload.bytes();
    if(bytes.empty()||!inspectAnnexB(bytes,sample.codec).valid)return VideoDelivery::Malformed;
    // Chiaki checks picture references and repairs recoverable gaps before this callback.
    sample.referencesValidated=true;
    return token.video(std::move(sample))?VideoDelivery::Queued:VideoDelivery::Discarded;
}
SessionInbox::Snapshot SessionInbox::snapshot()const{
    auto& s=*shared_;std::lock_guard l(s.mutex);Snapshot result{s.generation,s.state,s.stale,s.error,s.video.stats(),s.audio.stats()};
    const auto now=monotonic100ns();
    result.receivedBytes=s.receivedBytes;result.framesLost=s.framesLost;result.referenceRecoveryEvents=s.referenceRecoveryEvents;
    for(const auto& v:s.received)if(v.time>now-10000000){++result.receivedFps;result.videoMbps+=v.value*8/1000000;}
    return result;
}
bool SessionInbox::Token::video(VideoSample sample)const noexcept{
    try{auto s=shared_.lock();if(!s)return false;
        bool accepted=false;
        {std::lock_guard l(s->mutex);if(!s->current(generation_))return false;
        if(sample.generation!=generation_)return false;
        if(sample.kind==SampleKind::AccessUnit){s->receivedBytes+=sample.payload.bytes().size();s->framesLost+=std::max(0,sample.framesLost);s->referenceRecoveryEvents+=sample.referenceRecovered?1:0;Shared::add(s->received,monotonic100ns(),double(sample.payload.bytes().size()));}
        const auto r=s->video.push(std::move(sample),monotonic100ns());accepted=r==PushStatus::Accepted||r==PushStatus::ConfigStored;}
        // Wake even on WaitingForIdr: the owner must see the pending IDR request.
        s->wake();return accepted;
    }catch(...){failed(-1001);return false;}
}
bool SessionInbox::Token::audio(PcmBlock block)const noexcept{
    try{auto s=shared_.lock();if(!s)return false;bool accepted=false;
        {std::lock_guard l(s->mutex);if(!s->current(generation_)||block.generation!=generation_)return false;accepted=s->audio.push(std::move(block));}
        if(accepted)s->wake();return accepted;}
    catch(...){failed(-1002);return false;}
}
void SessionInbox::Token::connected()const noexcept{
    try{auto s=shared_.lock();if(!s)return;
        {std::lock_guard l(s->mutex);if(!s->current(generation_))return;
        if(s->state==SessionState::Connecting||s->state==SessionState::LoginPinRequired)s->state=SessionState::WaitingFirstFrame;}
        s->wake();
    }catch(...){}
}
void SessionInbox::Token::loginPinRequired()const noexcept{
    try{auto s=shared_.lock();if(!s)return;{std::lock_guard l(s->mutex);if(!s->current(generation_))return;s->state=SessionState::LoginPinRequired;++s->loginPinRequests;}s->wake();}catch(...){}
}
void SessionInbox::Token::failed(int code)const noexcept{
    try{auto s=shared_.lock();if(!s)return;
        {std::lock_guard l(s->mutex);if(!s->current(generation_))return;
        s->error=code;s->state=SessionState::Failed;s->accepting=false;s->video.close();s->audio.close();}
        s->wake();
    }catch(...){}
}
void SessionInbox::Token::wake()const noexcept{if(auto s=shared_.lock())s->wake();}
void SessionInbox::setWakeHook(WakeHook hook,void* user){
    auto& s=*shared_;std::lock_guard l(s.mutex);
    if(s.state!=SessionState::Idle)throw std::logic_error("Set the wake hook before begin()");
    s.wakeHook=hook;s.wakeUser=user;
}
SessionInbox::Status SessionInbox::status()const{auto& s=*shared_;std::lock_guard l(s.mutex);return {s.state,s.error,s.loginPinRequests};}
} // namespace framelift::remoteplay
