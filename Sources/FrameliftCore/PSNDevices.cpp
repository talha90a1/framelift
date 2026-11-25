// SPDX-License-Identifier: AGPL-3.0-only
#include "FrameliftBridge.h"
#include <arpa/inet.h>
#include <chiaki/remote/holepunch.h>
#include <algorithm>
#include <cstring>

namespace {
void quietLog(ChiakiLogLevel, const char*, void*) {}
}

extern "C" int32_t vr_psn_list_devices(const char* token, VRPSNDevice* out, int32_t max) {
    if (!token || !*token || !out || max <= 0 || max > 128) return -2001;
    if (vr_init() != 0) return -2002;
    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING, quietLog, nullptr);
    ChiakiHolepunchDeviceInfo* devices = nullptr;
    size_t count = 0;
    const auto error = chiaki_holepunch_list_devices(token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &log);
    if (error != CHIAKI_ERR_SUCCESS) {
        if (devices) chiaki_holepunch_free_device_list(&devices);
        return -2100;
    }
    const auto copied = std::min(count, static_cast<size_t>(max));
    for (size_t i = 0; i < copied; ++i) {
        out[i] = {};
        std::memcpy(out[i].uid, devices[i].device_uid, sizeof(out[i].uid));
        std::memcpy(out[i].name, devices[i].device_name, sizeof(devices[i].device_name));
        out[i].name[sizeof(out[i].name) - 1] = '\0';
        out[i].remote_play_enabled = devices[i].remoteplay_enabled;
    }
    chiaki_holepunch_free_device_list(&devices);
    return static_cast<int32_t>(copied);
}
