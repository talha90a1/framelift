// SPDX-License-Identifier: GPL-3.0-only
// Uses chiaki-ng's AGPL-3.0-only + OpenSSL-exception APIs; retain both licenses.
#include "veyra/remoteplay/ChiakiBackend.h"
#include <chiaki/session.h>
#if !defined(CHIAKI_VEYRA_VIDEO_METADATA_API) || CHIAKI_VEYRA_VIDEO_METADATA_API != 1
#error The reviewed Chiaki video metadata patch is required
#endif
#if !defined(CHIAKI_VEYRA_TAKION_V20_API) || CHIAKI_VEYRA_TAKION_V20_API != 1
#error Chiaki patch 0111 (Takion v20) is required: rebuild the dist with scripts/build_chiaki.sh
#endif
#include <chiaki/opusdecoder.h>
#include <chiaki/controller.h>
#include <chiaki/videoreceiver.h>
#include <chiaki/orientation.h>
#include <cmath>
#include <chiaki/log.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <set>
#include <string_view>
#include <thread>
#include <vector>
#include <cstdio>
#include <cstdlib>
namespace veyra::remoteplay {
static_assert(CHIAKI_PSN_ACCOUNT_ID_SIZE == 8);
static_assert(CHIAKI_SESSION_AUTH_SIZE == 16);
namespace {
void wipe(void* ptr,std::size_t n) noexcept {
    auto* p=static_cast<volatile unsigned char*>(ptr);
    while(n--) *p++=0;
}
BackendResult result(ChiakiErrorCode code,const char* operation) {
    return {code==CHIAKI_ERR_SUCCESS,static_cast<int>(code),operation};
}
}
PairingCredentials::PairingCredentials(PairingCredentials&& other) noexcept { *this=std::move(other); }
PairingCredentials& PairingCredentials::operator=(PairingCredentials&& other) noexcept {
    if(this==&other) return *this;
    registrationKey=other.registrationKey;sessionKey=other.sessionKey;accountId=other.accountId;
    wipe(other.registrationKey.data(),other.registrationKey.size());
    wipe(other.sessionKey.data(),other.sessionKey.size());wipe(other.accountId.data(),other.accountId.size());
    return *this;
}
PairingCredentials::~PairingCredentials(){wipe(registrationKey.data(),registrationKey.size());wipe(sessionKey.data(),sessionKey.size());wipe(accountId.data(),accountId.size());}
namespace {
std::atomic<ChiakiLogForwarder> logForwarder{nullptr};
std::atomic<std::uint32_t> logExtraLevels{0};

// Takion v20 fallback (chiaki patch 0111): a console whose v20 session never delivered video is
// offered only Takion 12 from the next connection.
std::mutex takionV20Mutex;
std::set<std::string> takionV20FailedHosts;
bool takionV20Disabled(const std::string& host){
    std::lock_guard lock(takionV20Mutex);return takionV20FailedHosts.count(host)!=0;
}
void markTakionV20Failed(const std::string& host,const char* why) noexcept {
    try{std::lock_guard lock(takionV20Mutex);if(!takionV20FailedHosts.insert(host).second)return;}catch(...){return;}
    char line[160];std::snprintf(line,sizeof(line),"Framelift: Takion v20 %s; this console streams on Takion 12 from the next connection",why);
    forwardChiakiLog(CHIAKI_LOG_WARNING,line);
}

// Multichannel Opus (5.1/7.1/7.1.4) down-mixed to stereo. Assumed layout (identity mapping,
// unverified): pair 0 = front L/R, further pairs = surround/height L/R, then centre and LFE
// (2 mono channels for 6, 8 and 12). LFE is dropped; gains are normalized so nothing clips.
void downmixToStereo(const std::int16_t* in,std::size_t frames,unsigned channels,std::int16_t* out) noexcept {
    const unsigned mono=(channels==6||channels==8||channels==12)?2u:channels%2u;
    const unsigned pairs=(channels-mono)/2u;
    constexpr float k=0.70710678f;
    const float norm=1.0f/(1.0f+k*float(pairs-1)+(mono?k:0.0f));
    for(std::size_t f=0;f<frames;++f,in+=channels,out+=2){
        float l=in[0],r=in[1];
        for(unsigned p=1;p<pairs;++p){l+=k*in[2*p];r+=k*in[2*p+1];}
        if(mono){const float c=k*in[2*pairs];l+=c;r+=c;}
        out[0]=static_cast<std::int16_t>(std::clamp(l*norm,-32768.0f,32767.0f));
        out[1]=static_cast<std::int16_t>(std::clamp(r*norm,-32768.0f,32767.0f));
    }
}
}
void setChiakiLogForwarder(ChiakiLogForwarder forwarder,std::uint32_t extraLevels){
    logExtraLevels=extraLevels&(CHIAKI_LOG_VERBOSE|CHIAKI_LOG_DEBUG);logForwarder=forwarder;
}
void forwardChiakiLog(int level,const char* line) noexcept {if(auto f=logForwarder.load();f&&line)f(level,line);}
std::uint32_t chiakiLogExtraLevels() noexcept {return logExtraLevels.load();}
BackendResult initializeChiaki(){
    static std::once_flag flag;
    static ChiakiErrorCode code=CHIAKI_ERR_UNKNOWN;
    std::call_once(flag,[]{code=chiaki_lib_init();});
    return result(code,"chiaki_lib_init");
}
struct ChiakiBackend::Impl {
    explicit Impl(SessionInbox::Token t):token(std::move(t)),owner(std::this_thread::get_id()){}
    SessionInbox::Token token;
    std::thread::id owner;
    ChiakiSession session{};
    ChiakiOpusDecoder opus{};
    ChiakiLog log{};
    VideoProfile profile;
    std::string host;
    bool initialized=false,opusInitialized=false;
    std::atomic<bool> active=false,started=false,connected=false;
    std::atomic<std::uint64_t> warnings=0,errors=0,videoCallbacks=0,audioCallbacks=0;
    std::atomic<int> quitReason=0,apiError=0;
    std::atomic<uint64_t> callbackRejected=0,transportErrors=0,assemblyErrors=0;
    std::atomic<int64_t> serverTargetBitrate=-1;
    std::atomic<uint64_t> qualityReports=0;
    // Framelift diagnostics (see NativeSnapshot).
    std::atomic<uint64_t> infos=0,fecSuccess=0,fecFailed=0,idrRetries=0,missingReferenceFrames=0,corruptFrameReports=0;
    std::atomic<uint64_t> metadataFramesLost=0,metadataRecoveredFrames=0,videoBytes=0;
    // Takion v20 (patch 0111), written by the session thread's event callback.
    std::atomic<int> takionVersion=0;
    std::atomic<bool> takionV20Offered=false;
    std::atomic<std::int64_t> connectedAtNs=0;
    std::atomic<std::uint32_t> audioSourceChannels=0;
    // Only the upstream audio/Opus callback thread reads/writes these fields.
    std::uint32_t channels=0,rate=0,sourceChannels=0; // channels: delivered (<=2); sourceChannels: decoded
    std::vector<std::int16_t> downmix;
    std::uint64_t sampleIndex=0;
    bool audioDiscontinuity=true;
    ChiakiOrientationTracker orientation{};ChiakiAccelNewZero accelZero{};
    uint64_t lastMotion=0;
    std::mutex feedbackMutex;ControllerFeedback feedback;

    static void logCallback(ChiakiLogLevel level,const char* message,void* user) noexcept {
        auto& self=*static_cast<Impl*>(user);
        if(message&&level==CHIAKI_LOG_VERBOSE){
            int target=-1;
            if(std::sscanf(message,"StreamConnection received connection quality: target_bitrate=%d,",&target)==1&&target>=0){self.serverTargetBitrate=target;++self.qualityReports;}
        }
        // Raw upstream log strings/hexdumps may contain keys. Do not forward them.
        if(level==CHIAKI_LOG_ERROR)++self.errors;
        if(level==CHIAKI_LOG_WARNING)++self.warnings;
        if(level==CHIAKI_LOG_INFO)++self.infos;
        // Framelift: count the upstream video-recovery events (fixed strings in
        // frameprocessor.c / videoreceiver.c) for diagnostics.
        if(message){
            const std::string_view text=message;
            if(text=="FEC successful")++self.fecSuccess;
            else if(text=="FEC failed")++self.fecFailed;
            else if(text.starts_with("Still waiting for IDR frame"))++self.idrRetries;
            else if(text.starts_with("Missing reference frame"))++self.missingReferenceFrames;
            else if(text.starts_with("Detected missing or corrupt frame"))++self.corruptFrameReports;
        }
        forwardChiakiLog(static_cast<int>(level),message); // forwarder redacts
        // Classify in memory; no upstream strings or hexdumps leave this callback.
        if(message&&(level==CHIAKI_LOG_ERROR||level==CHIAKI_LOG_WARNING)){
            const std::string_view text=message;
            if(text.find("Takion")!=text.npos||text.find("timeout")!=text.npos)++self.transportErrors;
            if(text.find("Video")!=text.npos||text.find("video")!=text.npos||text.find("frame")!=text.npos||text.find("FEC")!=text.npos)++self.assemblyErrors;
        }
    }
    static void eventCallback(ChiakiEvent* event,void* user) noexcept {
        auto& self=*static_cast<Impl*>(user);
        if(!event||!self.active.load())return;
        switch(event->type){
        case CHIAKI_EVENT_CONNECTED:{
            // Sent by the stream connection thread after the version switch: no race on these fields.
            const auto& stream=self.session.stream_connection;
            self.takionVersion=stream.takion.version;self.takionV20Offered=stream.takion_version_offered>=20;
            self.connectedAtNs=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
            char line[96];std::snprintf(line,sizeof(line),"Framelift: streaming on Takion %d%s",int(stream.takion.version),
                stream.takion_version_offered>=20?"":" (v20 not offered)");
            forwardChiakiLog(CHIAKI_LOG_INFO,line);
            self.connected=true;self.token.connected();break;}
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:self.token.loginPinRequired();break;
        case CHIAKI_EVENT_QUIT:
            // QUIT comes from the session thread after the stream connection ended.
            if(self.session.stream_connection.takion_version_offered>=20&&self.videoCallbacks.load()==0)
                markTakionV20Failed(self.host,"was offered but the session ended before any video");
            self.connected=false;self.quitReason=static_cast<int>(event->quit.reason);
            // A remote termination is not a successful decoded EOF.
            self.token.failed(2000+static_cast<int>(event->quit.reason));break;
        case CHIAKI_EVENT_RUMBLE:{std::lock_guard lock(self.feedbackMutex);self.feedback.rumble=true;self.feedback.left=event->rumble.left;self.feedback.right=event->rumble.right;break;}
        case CHIAKI_EVENT_TRIGGER_EFFECTS:{std::lock_guard lock(self.feedbackMutex);auto& f=self.feedback;f.triggers=true;f.leftTrigger[0]=event->trigger_effects.type_left;f.rightTrigger[0]=event->trigger_effects.type_right;std::copy_n(event->trigger_effects.left,10,f.leftTrigger.begin()+1);std::copy_n(event->trigger_effects.right,10,f.rightTrigger.begin()+1);break;}
        case CHIAKI_EVENT_MOTION_RESET:{std::lock_guard lock(self.feedbackMutex);self.feedback.motionReset=true;break;}
        default:return; // No mic, standby or keyboard side effects.
        }
        // Framelift: rumble/trigger/motion feedback wakes the session owner.
        switch(event->type){
        case CHIAKI_EVENT_RUMBLE:case CHIAKI_EVENT_TRIGGER_EFFECTS:case CHIAKI_EVENT_MOTION_RESET:self.token.wake();break;
        default:break;

        }
    }
    static void hapticsCallback(uint8_t* data,size_t size,void* user)noexcept{
        auto& self=*static_cast<Impl*>(user);
        if(!self.active||!data||!size||size%4||size>1200)return;
        try{std::lock_guard lock(self.feedbackMutex);auto& pcm=self.feedback.haptics;
            if(pcm.size()+size/2>600)pcm.clear();
            const auto at=pcm.size();pcm.resize(at+size/2);std::memcpy(pcm.data()+at,data,size);
        }catch(...){++self.errors;return;}
        self.token.wake(); // Framelift: deliver haptics without polling.
    }
    static bool videoCallback(std::uint8_t* data,std::size_t size,
        const ChiakiVeyraVideoSampleInfo* info,void* user) noexcept {
        auto& self=*static_cast<Impl*>(user);
        if(!data||!size||!info){++self.callbackRejected;return false;}
        // Only a non-Annex-B payload returns false: a false return makes Chiaki drop the reference
        // frame and send a corrupt-frame report for every following sample.
        if(!self.active.load())return true;
        try{
            VideoSample sample;
            sample.generation=self.token.generation();sample.arrival100ns=monotonic100ns();
            sample.codec=self.profile.codec;
            sample.kind=info->kind==CHIAKI_VEYRA_SAMPLE_FRAME?SampleKind::AccessUnit:SampleKind::CodecConfig;
            if(info->frame_index_valid)sample.wireFrameIndex=info->frame_index;
            sample.width=info->width;sample.height=info->height;
            sample.framesLost=info->frames_lost;sample.referenceRecovered=info->reference_recovered;
            if(info->frames_lost>0)self.metadataFramesLost+=static_cast<uint64_t>(info->frames_lost);
            if(info->reference_recovered)++self.metadataRecoveredFrames;
            self.videoBytes+=size;
            sample.payload=PaddedBytes::copy({data,size});++self.videoCallbacks;
            const auto delivery=deliverChiakiVideo(self.token,std::move(sample));
            if(delivery==VideoDelivery::Malformed)++self.callbackRejected;
            return chiakiVideoCallbackResult(delivery);
        }catch(...){self.apiError=-1001;self.token.failed(-1001);return false;}
    }
    static void opusSettings(std::uint32_t channels,std::uint32_t rate,void* user) noexcept {
        auto& self=*static_cast<Impl*>(user);
        // Sample position stays monotonic across repeated Opus headers within
        // one session; restarting at zero makes AudioIngress reject new PCM.
        // Takion v20 can switch the decoder to 5.1/7.1 (patch 0111): down-mix to stereo in opusFrame.
        self.sourceChannels=channels;self.channels=channels>2?2:channels;self.rate=rate;self.audioDiscontinuity=true;
        self.audioSourceChannels=channels;
        if(channels<1||channels>12||rate!=48000){self.channels=0;self.sourceChannels=0;self.token.failed(-1003);}
    }
    static void opusFrame(std::int16_t* data,std::size_t count,void* user) noexcept {
        auto& self=*static_cast<Impl*>(user);
        if(!self.active.load()||!self.channels||!data)return;
        if(count==0||count>self.rate/5u||count>(std::numeric_limits<std::uint64_t>::max)()-self.sampleIndex){self.token.failed(-1004);return;}
        try{
            PcmBlock block;block.generation=self.token.generation();block.channels=self.channels;block.rate=self.rate;
            block.firstSample=self.sampleIndex;block.arrival100ns=monotonic100ns();block.discontinuity=self.audioDiscontinuity;
            // Opus count is samples PER CHANNEL, not bytes or interleaved elements.
            if(self.sourceChannels>2){
                self.downmix.resize(count*2);downmixToStereo(data,count,self.sourceChannels,self.downmix.data());
                block.samples.assign(self.downmix.begin(),self.downmix.end());
            }else block.samples.assign(data,data+count*self.channels);
            self.sampleIndex+=count;++self.audioCallbacks;
            if(self.token.audio(std::move(block))) self.audioDiscontinuity=false;
        }catch(...){self.apiError=-1002;self.token.failed(-1002);}
    }
    BackendResult record(ChiakiErrorCode code,const char* name){apiError=static_cast<int>(code);return result(code,name);}
    bool onOwner()const noexcept{return owner==std::this_thread::get_id();}
};
ChiakiBackend::ChiakiBackend()=default;
ChiakiBackend::~ChiakiBackend(){
    if(!p_)return;
    try{
        const auto stopped=stop();
        if(!stopped.ok && p_){
            // Failed join: leak this session rather than free memory callbacks still use.
            p_->active=false;(void)p_.release();
        }
    }catch(...){if(p_){p_->active=false;(void)p_.release();}}
}
BackendResult ChiakiBackend::start(const NativeConnectRequest& request,SessionInbox::Token token){
    if(p_)return {false,-1100,"already_initialized"};
    if(!validHost(request.host)||request.video.validate()||token.generation()==0)return {false,-1101,"validate_connect"};
    auto init=initializeChiaki();if(!init.ok)return init;
    p_=std::make_unique<Impl>(std::move(token));auto& s=*p_;s.host=request.host;s.profile=request.video;
    // Framelift: INFO is always on (rare lines, needed for FEC/IDR counters); VERBOSE/DEBUG on opt-in.
    chiaki_log_init(&s.log,CHIAKI_LOG_WARNING|CHIAKI_LOG_ERROR|CHIAKI_LOG_INFO|chiakiLogExtraLevels(),Impl::logCallback,&s);
    ChiakiConnectInfo info{};info.ps5=true;info.host=s.host.c_str();
    info.disable_takion_v20=takionV20Disabled(s.host);
    std::memcpy(info.regist_key,request.credentials.registrationKey.data(),request.credentials.registrationKey.size());
    std::memcpy(info.morning,request.credentials.sessionKey.data(),request.credentials.sessionKey.size());
    std::memcpy(info.psn_account_id,request.credentials.accountId.data(),request.credentials.accountId.size());
    chiaki_connect_video_profile_preset(&info.video_profile,
        request.video.height==720?CHIAKI_VIDEO_RESOLUTION_PRESET_720p:CHIAKI_VIDEO_RESOLUTION_PRESET_1080p,
        request.video.fps==30?CHIAKI_VIDEO_FPS_PRESET_30:CHIAKI_VIDEO_FPS_PRESET_60);
    info.video_profile.codec=request.video.codec==Codec::H264?CHIAKI_CODEC_H264:request.video.codec==Codec::H265Hdr?CHIAKI_CODEC_H265_HDR:CHIAKI_CODEC_H265;
    info.video_profile.bitrate=request.video.bitrateKbps;
    info.video_profile_auto_downgrade=false;info.enable_keyboard=false;info.enable_dualsense=true;
    info.auto_regist=false;info.packet_loss_max=0.05;info.enable_idr_on_fec_failure=false /* chiaki-ng's default; reference-recovery frames keep the picture moving */;
    const auto code=chiaki_session_init(&s.session,&info,&s.log);
    wipe(info.regist_key,sizeof(info.regist_key));wipe(info.morning,sizeof(info.morning));wipe(info.psn_account_id,sizeof(info.psn_account_id));
    if(code!=CHIAKI_ERR_SUCCESS){auto out=s.record(code,"chiaki_session_init");s.token.failed(out.code);p_.reset();return out;}
    s.initialized=true;
    chiaki_opus_decoder_init(&s.opus,&s.log);s.opusInitialized=true;
    chiaki_opus_decoder_set_cb(&s.opus,Impl::opusSettings,Impl::opusFrame,&s);
    ChiakiAudioSink sink{};chiaki_opus_decoder_get_sink(&s.opus,&sink);chiaki_session_set_audio_sink(&s.session,&sink);
    ChiakiAudioSink hapticSink{};hapticSink.user=&s;hapticSink.frame_cb=Impl::hapticsCallback;
    chiaki_session_set_haptics_sink(&s.session,&hapticSink);
    chiaki_session_set_event_cb(&s.session,Impl::eventCallback,&s);
    chiaki_session_set_veyra_video_sample_cb(&s.session,Impl::videoCallback,&s);
    s.active=true;
    const auto startCode=chiaki_session_start(&s.session);
    if(startCode!=CHIAKI_ERR_SUCCESS){auto out=s.record(startCode,"chiaki_session_start");s.active=false;s.token.failed(out.code);(void)stop();return out;}
    s.started=true;return s.record(startCode,"chiaki_session_start");
}
BackendResult ChiakiBackend::stop(){
    if(!p_)return {true,0,"already_stopped"};
    auto& s=*p_;
    if(!s.onOwner())return {false,-1102,"wrong_owner_thread"};
    s.active=false;
    // A v20 stream that connected but showed no video for 5 s: stream the next connection on 12.
    if(s.connected&&s.takionVersion==20&&s.videoCallbacks.load()==0){
        const auto now=std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        if(now-s.connectedAtNs.load()>=5'000'000'000LL)markTakionV20Failed(s.host,"streamed no video for 5 s");
    }
    ChiakiErrorCode stopResult=CHIAKI_ERR_SUCCESS;
    if(s.started){
        ChiakiControllerState idle;chiaki_controller_state_set_idle(&idle);
        (void)s.record(chiaki_session_set_controller_state(&s.session,&idle),"release_controller");
        const auto stopCode=chiaki_session_stop(&s.session);
        stopResult=stopCode;
        // Join even if stop reported an error. Never fini while a callback is alive.
        const auto joinCode=chiaki_session_join(&s.session);
        if(joinCode!=CHIAKI_ERR_SUCCESS)return s.record(joinCode,"chiaki_session_join");
        s.started=false;s.connected=false;
        if(stopCode!=CHIAKI_ERR_SUCCESS)s.apiError=static_cast<int>(stopCode);
    }
    if(s.opusInitialized){chiaki_opus_decoder_fini(&s.opus);s.opusInitialized=false;}
    if(s.initialized){chiaki_session_fini(&s.session);s.initialized=false;}
    wipe(&s.session,sizeof(s.session));
    p_.reset();return result(stopResult,"stop_join_fini");
}
BackendResult ChiakiBackend::requestIdr(){
    if(!p_||!p_->onOwner()||!p_->started)return {false,-1103,"idr_without_session"};
    const auto code=chiaki_session_request_idr(&p_->session);
    // Mark the receiver as waiting so upstream re-requests the IDR every second until one arrives.
    // Upstream frees the receiver under state_mutex at stream end, so hold it here.
    if(code==CHIAKI_ERR_SUCCESS){
        auto& stream=p_->session.stream_connection;
        if(chiaki_mutex_lock(&stream.state_mutex)==CHIAKI_ERR_SUCCESS){
            if(stream.video_receiver)chiaki_video_receiver_set_waiting_for_idr(stream.video_receiver,true);
            chiaki_mutex_unlock(&stream.state_mutex);
        }
    }
    return p_->record(code,"chiaki_session_request_idr");
}
BackendResult ChiakiBackend::submitLoginPin(std::string_view pin){
    if(!p_||!p_->onOwner()||!p_->started)return {false,-1104,"pin_without_session"};
    if(pin.empty()||pin.size()>8||!std::all_of(pin.begin(),pin.end(),[](char c){return c>='0'&&c<='9';}))return {false,-1105,"invalid_login_pin"};
    return p_->record(chiaki_session_set_login_pin(&p_->session,reinterpret_cast<const std::uint8_t*>(pin.data()),pin.size()),"chiaki_session_set_login_pin");
}
BackendResult ChiakiBackend::submitController(const ControllerState& state){
    if(!p_||!p_->onOwner()||!p_->started)return {false,-1106,"controller_without_session"};
    ChiakiControllerState c;chiaki_controller_state_set_idle(&c);
    struct Mapping{std::uint32_t semantic;ChiakiControllerButton target;};
    static constexpr Mapping buttons[]={
        {ControllerState::Cross,CHIAKI_CONTROLLER_BUTTON_CROSS},{ControllerState::Circle,CHIAKI_CONTROLLER_BUTTON_MOON},
        {ControllerState::Square,CHIAKI_CONTROLLER_BUTTON_BOX},{ControllerState::Triangle,CHIAKI_CONTROLLER_BUTTON_PYRAMID},
        {ControllerState::Left,CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT},{ControllerState::Right,CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT},
        {ControllerState::Up,CHIAKI_CONTROLLER_BUTTON_DPAD_UP},{ControllerState::Down,CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN},
        {ControllerState::L1,CHIAKI_CONTROLLER_BUTTON_L1},{ControllerState::R1,CHIAKI_CONTROLLER_BUTTON_R1},
        {ControllerState::L3,CHIAKI_CONTROLLER_BUTTON_L3},{ControllerState::R3,CHIAKI_CONTROLLER_BUTTON_R3},
        {ControllerState::Options,CHIAKI_CONTROLLER_BUTTON_OPTIONS},{ControllerState::Share,CHIAKI_CONTROLLER_BUTTON_SHARE},
        {ControllerState::Touchpad,CHIAKI_CONTROLLER_BUTTON_TOUCHPAD},{ControllerState::PS,CHIAKI_CONTROLLER_BUTTON_PS}};
    for(auto b:buttons)if(state.buttons&b.semantic)c.buttons|=static_cast<std::uint32_t>(b.target);
    for(size_t i=0;i<state.touches.size();++i){c.touches[i].id=state.touches[i].id;c.touches[i].x=state.touches[i].x;c.touches[i].y=state.touches[i].y;}
    const auto applyMotion=[&](const std::array<float,3>& gyro,const std::array<float,3>& accel,uint64_t timestamp){
        if(!timestamp||!std::all_of(gyro.begin(),gyro.end(),[](float v){return std::isfinite(v);})||!std::all_of(accel.begin(),accel.end(),[](float v){return std::isfinite(v);}))return;
        // Repeated state snapshots contain the same batch; never integrate twice.
        if(p_->lastMotion&&timestamp<=p_->lastMotion)return;
        if(!p_->lastMotion||timestamp-p_->lastMotion>100000){chiaki_orientation_tracker_init(&p_->orientation);chiaki_accel_new_zero_set_inactive(&p_->accelZero,false);}
        chiaki_orientation_tracker_update(&p_->orientation,gyro[0],gyro[1],gyro[2],accel[0],accel[1],accel[2],&p_->accelZero,false,uint32_t(timestamp));p_->lastMotion=timestamp;
    };
    if(state.motionValid){
        for(size_t i=0;i<std::min(size_t(state.motionSampleCount),state.motionSamples.size());++i){const auto& sample=state.motionSamples[i];applyMotion(sample.gyro,sample.accel,sample.timestampUs);}
        applyMotion(state.gyro,state.accel,state.motionTimestampUs);
        chiaki_orientation_tracker_apply_to_controller_state(&p_->orientation,&c);
    }else p_->lastMotion=0;
    c.l2_state=state.l2;c.r2_state=state.r2;c.left_x=state.leftX;c.left_y=state.leftY;c.right_x=state.rightX;c.right_y=state.rightY;
    return p_->record(chiaki_session_set_controller_state(&p_->session,&c),"chiaki_session_set_controller_state");
}
ControllerFeedback ChiakiBackend::takeFeedback(){
    if(!p_||!p_->onOwner())return {};
    std::lock_guard lock(p_->feedbackMutex);auto result=std::move(p_->feedback);p_->feedback={};
    if(result.motionReset)p_->lastMotion=0;
    return result;
}
NativeSnapshot ChiakiBackend::snapshot()const{
    // Like start/stop, pointer ownership requires the owner; the atomic counters
    // themselves may be updated by callbacks. Do not call concurrently with reset.
    if(!p_)return {};
    auto& s=*p_;
    NativeSnapshot out{s.connected.load(),s.warnings.load(),s.errors.load(),s.videoCallbacks.load(),s.audioCallbacks.load(),s.quitReason.load(),s.apiError.load()};
    out.callbackRejected=s.callbackRejected;out.transportErrors=s.transportErrors;out.assemblyErrors=s.assemblyErrors;
    out.serverTargetBitrate=s.serverTargetBitrate;out.qualityReports=s.qualityReports;
    out.infos=s.infos;out.fecSuccess=s.fecSuccess;out.fecFailed=s.fecFailed;out.idrRetries=s.idrRetries;
    out.missingReferenceFrames=s.missingReferenceFrames;out.corruptFrameReports=s.corruptFrameReports;
    out.metadataFramesLost=s.metadataFramesLost;out.metadataRecoveredFrames=s.metadataRecoveredFrames;out.videoBytes=s.videoBytes;
    // Upstream packet window may reset itself; do not label this cumulative UDP.
    if(s.initialized){
        chiaki_packet_stats_get(&s.session.stream_connection.packet_stats,false,&out.packetReceived,&out.packetLost);
        chiaki_packet_stats_get_total(&s.session.stream_connection.packet_stats,&out.packetReceivedTotal,&out.packetLostTotal);
    }
    out.takionVersion=s.takionVersion;out.takionV20Offered=s.takionV20Offered;out.audioSourceChannels=s.audioSourceChannels;
    return out;
}
} // namespace veyra::remoteplay
