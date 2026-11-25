// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "framelift/remoteplay/SessionInbox.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <pthread/qos.h>
#include <thread>
#include <utility>

namespace framelift {
struct VideoDeliveryWake {
    std::mutex mutex;
    std::condition_variable cv;
    bool pending = false;

    void notify() noexcept {
        { std::lock_guard lock(mutex); pending = true; }
        cv.notify_one();
    }
};

class VideoDeliveryWorker {
public:
    using Deliver = std::function<void(framelift::remoteplay::QueuedVideo)>;

    VideoDeliveryWorker(framelift::remoteplay::SessionInbox& inbox, VideoDeliveryWake& wake, Deliver deliver)
        : inbox_(inbox), wake_(wake), deliver_(std::move(deliver)),
          thread_([this](std::stop_token stop) { run(stop); }) {}

    ~VideoDeliveryWorker() { stop(); }
    VideoDeliveryWorker(const VideoDeliveryWorker&) = delete;
    VideoDeliveryWorker& operator=(const VideoDeliveryWorker&) = delete;

    void stop() {
        if (!thread_.joinable()) return;
        thread_.request_stop();
        wake_.notify();
        thread_.join();
    }

    bool failed() const noexcept { return failed_.load(std::memory_order_acquire); }

private:
    void run(std::stop_token stop) noexcept {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        try {
            while (!stop.stop_requested()) {
                {
                    std::unique_lock lock(wake_.mutex);
                    wake_.cv.wait_for(lock, std::chrono::milliseconds(1), [&] { return wake_.pending || stop.stop_requested(); });
                    wake_.pending = false;
                }
                while (!stop.stop_requested()) {
                    auto unit = inbox_.tryVideo(framelift::remoteplay::monotonic100ns());
                    if (!unit || stop.stop_requested()) break;
                    deliver_(std::move(*unit));
                }
            }
        } catch (...) { failed_.store(true, std::memory_order_release); }
    }

    framelift::remoteplay::SessionInbox& inbox_;
    VideoDeliveryWake& wake_;
    Deliver deliver_;
    std::atomic<bool> failed_{false};
    std::jthread thread_;
};
} // namespace framelift
