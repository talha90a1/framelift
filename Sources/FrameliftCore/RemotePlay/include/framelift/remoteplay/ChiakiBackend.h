// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "SessionInbox.h"
#include <array>
#include <chrono>
#include <memory>
#include <stop_token>
#include <string>

namespace framelift::remoteplay {
// No serialization/ostream support: never put registration/session keys into
// command lines, logs, fixtures or source control.
struct PairingCredentials {
    PairingCredentials() = default;
    PairingCredentials(const PairingCredentials&) = delete;
    PairingCredentials& operator=(const PairingCredentials&) = delete;
    PairingCredentials(PairingCredentials&&) noexcept;
    PairingCredentials& operator=(PairingCredentials&&) noexcept;
    AccountId accountId{};
    std::array<char,16> registrationKey{};
    std::array<std::uint8_t,16> sessionKey{};
    ~PairingCredentials();
};
struct BackendResult {
    bool ok=false;
    int code=0;
    // One of the fixed operation names, never an unfiltered server string.
    std::string operation;
};
struct NativeConnectRequest {
    std::string host;
    VideoProfile video;
    PairingCredentials credentials;
    void* internetSession = nullptr;
};
struct NativeSnapshot {
    bool connected=false;
    std::uint64_t warnings=0,errors=0,videoCallbacks=0,audioCallbacks=0;
    int lastQuitReason=0,lastApiError=0;
    // callbackRejected counts samples Chiaki was told failed (non-Annex-B payload only).
    uint64_t callbackRejected=0,packetReceived=0,packetLost=0;
    uint64_t transportErrors=0,assemblyErrors=0;
    int64_t serverTargetBitrate=-1; // Raw upstream field; diagnostic opt-in only.
    uint64_t qualityReports=0;
    // Classified upstream log events (INFO is always captured
    // for classification; only the forwarder decides what leaves the process).
    uint64_t infos=0,fecSuccess=0,fecFailed=0,idrRetries=0,missingReferenceFrames=0,corruptFrameReports=0;
    // From the per-sample video metadata (patch 0002), counted before the inbox.
    uint64_t metadataFramesLost=0,metadataRecoveredFrames=0,videoBytes=0;
    // Takion v20 (patch 0111): version streamed (0 until connected), whether 20 was offered,
    // whole-session packet totals (the windowed counters above reset every 200 ms) and the
    // console's audio channel count before the stereo down-mix.
    int takionVersion=0;
    bool takionV20Offered=false;
    uint64_t packetReceivedTotal=0,packetLostTotal=0;
    std::uint32_t audioSourceChannels=0;
};
// Process-wide forwarder for upstream log lines. The forwarder MUST redact:
// raw upstream lines can contain hexdumps and key material. levelMask uses ChiakiLogLevel bits;
// WARNING|ERROR|INFO are always requested from Chiaki (for counters), VERBOSE/DEBUG only on opt-in.
using ChiakiLogForwarder=void(*)(int level,const char* line) noexcept;
void setChiakiLogForwarder(ChiakiLogForwarder forwarder,std::uint32_t extraLevels);
void forwardChiakiLog(int level,const char* line) noexcept;
std::uint32_t chiakiLogExtraLevels() noexcept;
BackendResult initializeChiaki();
class ChiakiBackend {
public:
    ChiakiBackend();
    ~ChiakiBackend();
    ChiakiBackend(const ChiakiBackend&)=delete;
    ChiakiBackend& operator=(const ChiakiBackend&)=delete;
    // All methods, including snapshot(), must be called from one session-owner thread,
    // NEVER from a Chiaki callback. This object is not a renderer or a decoder.
    BackendResult start(const NativeConnectRequest&,SessionInbox::Token);
    BackendResult stop(); // Does not call PS5 goto_bed; must precede inbox.finishStop().
    BackendResult requestIdr();
    BackendResult submitController(const ControllerState&);
    BackendResult submitLoginPin(std::string_view);
    NativeSnapshot snapshot() const;
    ControllerFeedback takeFeedback();
private:
    struct Impl;
    std::unique_ptr<Impl> p_;
};
struct PairResult {
    BackendResult result;
    PairingCredentials credentials;
    std::array<std::uint8_t,6> mac{};
    std::string nickname;
    bool canceled=false,timedOut=false;
    // The console's rejection reason (HTTP code / RP-Application-Reason), no secrets.
    std::string detail;
};
// Synchronous OWNERSHIP operation; run on a dedicated session/setup worker.
// Cancellation stops the upstream registration and joins before returning.
PairResult pairLocalPs5(std::string host,const AccountId&,std::string_view eightDigitPin,
    std::stop_token stop={},std::chrono::milliseconds timeout=std::chrono::seconds(30));
} // namespace framelift::remoteplay
