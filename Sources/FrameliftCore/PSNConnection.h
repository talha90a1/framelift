// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <arpa/inet.h>
#include <chiaki/remote/holepunch.h>
#include <atomic>
#include <functional>
#include <mutex>

class PSNConnection {
public:
    PSNConnection() { chiaki_log_init(&log_, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING, quietLog, nullptr); }
    ~PSNConnection() {
        if (!owned_ || !session_) return;
        for (auto type : {CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL, CHIAKI_HOLEPUNCH_PORT_TYPE_DATA}) {
            auto* socket = chiaki_get_holepunch_sock(session_, type);
            if (socket && !CHIAKI_SOCKET_IS_INVALID(*socket)) {
                CHIAKI_SOCKET_CLOSE(*socket);
                *socket = CHIAKI_INVALID_SOCKET;
            }
        }
        chiaki_holepunch_session_fini(session_);
    }

    ChiakiErrorCode prepare(const char* token, const uint8_t uid[32], const std::function<void(int)>& progress) {
        {
            std::lock_guard lock(mutex_);
            if (canceled_) return CHIAKI_ERR_CANCELED;
            session_ = chiaki_holepunch_session_init(token, &log_);
        }
        if (!session_) return CHIAKI_ERR_MEMORY;
        progress(1);
        auto err = chiaki_holepunch_upnp_discover(session_);
        if (err != CHIAKI_ERR_SUCCESS || canceled_) return canceled_ ? CHIAKI_ERR_CANCELED : err;
        err = chiaki_holepunch_session_create(session_);
        if (err != CHIAKI_ERR_SUCCESS || canceled_) return canceled_ ? CHIAKI_ERR_CANCELED : err;
        err = holepunch_session_create_offer(session_);
        if (err != CHIAKI_ERR_SUCCESS || canceled_) return canceled_ ? CHIAKI_ERR_CANCELED : err;
        progress(2);
        err = chiaki_holepunch_session_start(session_, uid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5);
        if (err != CHIAKI_ERR_SUCCESS || canceled_) return canceled_ ? CHIAKI_ERR_CANCELED : err;
        progress(3);
        return chiaki_holepunch_session_punch_hole(session_, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
    }

    template<class Start> auto handoff(Start start) {
        std::lock_guard lock(mutex_);
        owned_ = false; // chiaki_session_init consumes the handle, including on failure.
        auto result = start(session_);
        if (!result.ok) session_ = nullptr;
        return result;
    }

    void cancel() {
        std::lock_guard lock(mutex_);
        canceled_ = true;
        if (session_) chiaki_holepunch_main_thread_cancel(session_, true);
    }

    void disarm() {
        std::lock_guard lock(mutex_);
        if (!owned_) session_ = nullptr;
    }

private:
    static void quietLog(ChiakiLogLevel, const char*, void*) {}
    ChiakiLog log_{};
    std::mutex mutex_;
    std::atomic<bool> canceled_{false};
    ChiakiHolepunchSession session_ = nullptr;
    bool owned_ = true;
};
