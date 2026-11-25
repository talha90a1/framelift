// SPDX-License-Identifier: GPL-3.0-only
// Framelift: ported from Veyra's Windows Discovery.cpp. Broadcast targets
// come from getifaddrs instead of iphlpapi GetAdaptersAddresses.
#include "framelift/remoteplay/Discovery.h"
#include <chiaki/discoveryservice.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <algorithm>
#include <charconv>
#include <condition_variable>
#include <mutex>
namespace framelift::remoteplay {
namespace {
struct DiscoveryResult {
    std::mutex mutex;DiscoveryReport report;bool includePs4=false;
    static void logging(ChiakiLogLevel level,const char* message,void* user) noexcept {
        try {auto& out=*static_cast<DiscoveryResult*>(user);std::lock_guard lock(out.mutex);
            // A failed sendto on one interface is logged as ERROR by chiaki; only forward it
            // so discovery on the remaining interfaces still counts.
            forwardChiakiLog(static_cast<int>(level),message); // forwarder redacts
        }catch(...){}
    }
    static void receive(ChiakiDiscoveryHost* hosts,size_t count,void* user) noexcept {
        auto& out=*static_cast<DiscoveryResult*>(user);
        try{std::lock_guard lock(out.mutex);out.report.hosts.clear();
            for(size_t i=0;i<std::min(count,size_t(16));++i){
                const bool ps5=chiaki_discovery_host_is_ps5(&hosts[i]);
                if((ps5||out.includePs4)&&hosts[i].host_addr&&validHost(hosts[i].host_addr))
                    out.report.hosts.push_back({hosts[i].host_addr,hosts[i].state==CHIAKI_DISCOVERY_HOST_STATE_STANDBY,
                        hosts[i].host_id?hosts[i].host_id:"",hosts[i].host_name?hosts[i].host_name:"",ps5});
            }
        }catch(...){/* Keep callback exceptions out of C. */}
    }
};
void quiet(ChiakiLogLevel,const char*,void*){}
std::vector<sockaddr_storage> broadcastTargets(){
    std::vector<sockaddr_storage> out;
    ifaddrs* list=nullptr;
    if(getifaddrs(&list)!=0)return out;
    for(auto* entry=list;entry;entry=entry->ifa_next){
        const auto flags=entry->ifa_flags;
        if(!entry->ifa_addr||entry->ifa_addr->sa_family!=AF_INET||!entry->ifa_netmask)continue;
        if(!(flags&IFF_UP)||!(flags&IFF_RUNNING)||!(flags&IFF_BROADCAST)||(flags&IFF_LOOPBACK)||(flags&IFF_POINTOPOINT))continue;
        const auto address=ntohl(reinterpret_cast<sockaddr_in*>(entry->ifa_addr)->sin_addr.s_addr);
        const auto mask=ntohl(reinterpret_cast<sockaddr_in*>(entry->ifa_netmask)->sin_addr.s_addr);
        // Same filters as the Windows build: skip loopback, link-local, /31-/32 and empty prefixes.
        if((address>>24)==127||(address>>16)==0xa9fe||address==0||mask==0||(~mask)<3)continue;
        sockaddr_storage target{};auto* ipv4=reinterpret_cast<sockaddr_in*>(&target);
        ipv4->sin_len=sizeof(sockaddr_in);ipv4->sin_family=AF_INET;ipv4->sin_addr.s_addr=htonl(address|~mask);
        if(std::any_of(out.begin(),out.end(),[&](const auto& old){return reinterpret_cast<const sockaddr_in*>(&old)->sin_addr.s_addr==ipv4->sin_addr.s_addr;}))continue;
        out.push_back(target);
    }
    freeifaddrs(list);
    return out;
}
}
DiscoveryReport discoverLocalConsoles(std::stop_token stop,std::chrono::milliseconds timeout,bool includePs4){
    if(stop.stop_requested())return {};
    auto initialized=initializeChiaki();
    if(!initialized.ok)return {{},initialized.code};
    DiscoveryResult result;result.includePs4=includePs4;ChiakiLog log{};
    chiaki_log_init(&log,CHIAKI_LOG_ERROR|CHIAKI_LOG_WARNING|CHIAKI_LOG_INFO,DiscoveryResult::logging,&result);
    auto broadcasts=broadcastTargets();
    if(broadcasts.empty())return {{},-1401};
    sockaddr_storage address{};auto* ipv4=reinterpret_cast<sockaddr_in*>(&address);
    ipv4->sin_len=sizeof(sockaddr_in);ipv4->sin_family=AF_INET;ipv4->sin_addr.s_addr=INADDR_BROADCAST;ipv4->sin_port=htons(CHIAKI_DISCOVERY_PORT_PS5);
    ChiakiDiscoveryServiceOptions options{};options.hosts_max=16;options.host_drop_pings=20;options.ping_ms=500;options.ping_initial_ms=0;
    options.send_addr=&address;options.send_addr_size=sizeof(sockaddr_in);options.cb=DiscoveryResult::receive;options.cb_user=&result;
    options.broadcast_addrs=broadcasts.data();options.broadcast_num=broadcasts.size();
    ChiakiDiscoveryService service{};
    const auto started=chiaki_discovery_service_init(&service,&options,&log);
    if(started!=CHIAKI_ERR_SUCCESS){result.report.error=int(started);return std::move(result.report);}
    {
        std::mutex mutex;std::condition_variable_any wait;std::unique_lock lock(mutex);
        wait.wait_for(lock,stop,timeout,[]{return false;});
    }
    chiaki_discovery_service_fini(&service);
    std::lock_guard lock(result.mutex);
    return std::move(result.report);
}
BackendResult wakeLocalPs5(const NativeConnectRequest& request){
    if(!validHost(request.host))return {false,-1300,"invalid_wakeup_host"};
    auto init=initializeChiaki();if(!init.ok)return init;
    const auto& key=request.credentials.registrationKey;
    const auto end=std::find(key.begin(),key.end(),'\0');uint64_t credential=0;
    const auto parsed=std::from_chars(key.data(),key.data()+(end-key.begin()),credential,16);
    if(parsed.ec!=std::errc{}||parsed.ptr!=key.data()+(end-key.begin()))return {false,-1301,"invalid_wakeup_credential"};
    ChiakiLog log{};chiaki_log_init(&log,0,quiet,nullptr);
    const auto code=chiaki_discovery_wakeup(&log,nullptr,request.host.c_str(),credential,true);
    return {code==CHIAKI_ERR_SUCCESS,int(code),"chiaki_discovery_wakeup"};
}
}
