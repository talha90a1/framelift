// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "ChiakiBackend.h"
#include <chrono>
#include <vector>
namespace veyra::remoteplay {
// Framelift: name/isPs5 added (PS4 hosts are only returned when includePs4 is set).
struct DiscoveredConsole {std::string host;bool standby=false;std::string consoleId;std::string name;bool isPs5=true;};
struct DiscoveryReport {
    std::vector<DiscoveredConsole> hosts;
    int error=0;
};
// Framelift: bounded wait.
DiscoveryReport discoverLocalConsoles(std::stop_token,std::chrono::milliseconds timeout,bool includePs4);
BackendResult wakeLocalPs5(const NativeConnectRequest&);
}
