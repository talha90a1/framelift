// SPDX-License-Identifier: GPL-3.0-only
// PS5 registration (pairing) through chiaki-ng; do not call from the UI thread.
#include "veyra/remoteplay/ChiakiBackend.h"
#include <chiaki/regist.h>
#include <chiaki/log.h>
#include <condition_variable>
#include <algorithm>
#include <cstring>
#include <mutex>
namespace veyra::remoteplay {
namespace {
struct RegistrationWait {
    std::mutex mutex;std::condition_variable cv;bool done=false,success=false;
    std::array<char,16> registrationKey{};std::array<std::uint8_t,16> sessionKey{};
    std::array<std::uint8_t,6> mac{};std::array<char,32> nickname{};
    std::string detail; // Framelift: whitelisted rejection lines only
    ~RegistrationWait(){
        auto wipe=[](void* p,std::size_t n){auto* b=static_cast<volatile unsigned char*>(p);while(n--)*b++=0;};
        wipe(registrationKey.data(),registrationKey.size());wipe(sessionKey.data(),sessionKey.size());
    }
    static void callback(ChiakiRegistEvent* event,void* user) noexcept{
        auto& s=*static_cast<RegistrationWait*>(user);
        try{
            std::lock_guard lock(s.mutex);
            s.success=event&&event->type==CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS&&event->registered_host;
            if(s.success){
                const auto& h=*event->registered_host;
                std::memcpy(s.registrationKey.data(),h.rp_regist_key,s.registrationKey.size());
                std::memcpy(s.sessionKey.data(),h.rp_key,s.sessionKey.size());
                std::memcpy(s.mac.data(),h.server_mac,s.mac.size());
                std::memcpy(s.nickname.data(),h.server_nickname,s.nickname.size());
            }
            s.done=true;s.cv.notify_all();
        }catch(...){/* Allocation-free callback; owner still has timeout/cancel. */}
    }
    // Framelift: registration responses can carry credentials, so only these fixed upstream
    // messages (status code, Sony's reason, refused search) are kept. Everything else is dropped.
    static void log(ChiakiLogLevel,const char* message,void* user)noexcept{
        if(!message||!user)return;
        const std::string_view m=message;
        if(!(m.starts_with("Regist received HTTP code")||m.starts_with("Reported Application Reason")||
             m.starts_with("The console refused")||m.starts_with("Regist timed out")||m.starts_with("Regist eventually failed")))return;
        try{auto& s=*static_cast<RegistrationWait*>(user);std::lock_guard lock(s.mutex);
            if(!s.detail.empty())s.detail+="; ";s.detail+=std::string(m.substr(0,160));}catch(...){}
    }
};
}
PairResult pairLocalPs5(std::string host,const AccountId& account,std::string_view pin,
    std::stop_token cancel,std::chrono::milliseconds timeout){
    PairResult out;auto numericPin=parsePairingPin(pin);
    if(!validHost(host)||!numericPin||timeout<std::chrono::seconds(1)||timeout>std::chrono::seconds(60)){
        out.result={false,-1200,"validate_registration"};return out;
    }
    if(cancel.stop_requested()){out.canceled=true;out.result={false,-1201,"registration_canceled"};return out;}
    out.result=initializeChiaki();if(!out.result.ok)return out;
    RegistrationWait wait;ChiakiRegist registration{};ChiakiLog log{};
    // Do not emit raw registration responses: they contain pairing credentials.
    chiaki_log_init(&log,CHIAKI_LOG_ERROR,RegistrationWait::log,&wait);
    ChiakiRegistInfo info{};info.target=CHIAKI_TARGET_PS5_1;info.host=host.c_str();info.broadcast=false;
    info.psn_online_id=nullptr;info.pin=*numericPin;
    std::memcpy(info.psn_account_id,account.data(),account.size());
    const auto started=chiaki_regist_start(&registration,&log,&info,RegistrationWait::callback,&wait);
    info.pin=0;
    if(started!=CHIAKI_ERR_SUCCESS){out.result={false,static_cast<int>(started),"chiaki_regist_start"};return out;}
    {
        // stop_callback only wakes the owner. No upstream stop/join on callback thread.
        std::stop_callback notify(cancel,[&wait]{std::lock_guard lock(wait.mutex);wait.cv.notify_all();});
        std::unique_lock lock(wait.mutex);
        const bool ready=wait.cv.wait_for(lock,timeout,[&]{return wait.done||cancel.stop_requested();});
        out.canceled=cancel.stop_requested();out.timedOut=!ready;
    }
    // fini includes join in the pinned upstream. Must not hold wait.mutex here.
    chiaki_regist_stop(&registration);chiaki_regist_fini(&registration);
    if(out.canceled||out.timedOut){out.result={false,out.canceled?-1201:-1202,out.canceled?"registration_canceled":"registration_timeout"};return out;}
    if(!wait.success){out.detail=wait.detail;out.result={false,-1203,"registration_failed"};return out;}
    out.credentials.accountId=account;out.credentials.registrationKey=wait.registrationKey;out.credentials.sessionKey=wait.sessionKey;out.mac=wait.mac;
    const auto length=std::find(wait.nickname.begin(),wait.nickname.end(),'\0')-wait.nickname.begin();
    out.nickname.assign(wait.nickname.data(),static_cast<std::size_t>(length));
    out.result={true,0,"registration_completed"};return out;
}
} // namespace veyra::remoteplay
