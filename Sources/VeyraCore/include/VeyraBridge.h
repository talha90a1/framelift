// SPDX-License-Identifier: AGPL-3.0-only
// C ABI between the Swift app and Veyra's ported remote-play core (C++20) on top of chiaki-ng.
// Credentials passed in here are never logged or persisted by the core (the app stores them).
#ifndef VEYRA_BRIDGE_H
#define VEYRA_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum VRCodec { VR_CODEC_H264 = 0, VR_CODEC_H265 = 1, VR_CODEC_H265_HDR = 2 } VRCodec;

typedef struct VRVideoProfile {
    uint32_t width;        // 1280 or 1920 (PS5 presets 720p / 1080p)
    uint32_t height;       // 720 or 1080
    uint32_t fps;          // 30 or 60 (stream preset; for 30 fps games use 30 and interpolate)
    uint32_t bitrate_kbps; // e.g. 15000
    VRCodec codec;
} VRVideoProfile;

typedef struct VRCredentials {
    uint8_t account_id[8];     // PSN account id (binary, little endian as chiaki expects)
    char regist_key[16];       // from registration
    uint8_t morning[16];       // session key ("morning") from registration
} VRCredentials;

typedef enum VREventType {
    VR_EVENT_CONNECTED = 1,
    VR_EVENT_LOGIN_PIN_REQUEST = 2,
    VR_EVENT_QUIT = 3,          // code = chiaki quit reason
    VR_EVENT_FAILED = 4,        // code = negative Veyra/bridge error or chiaki error
    VR_EVENT_RUMBLE = 5,        // a = left (0-255), b = right (0-255)
    VR_EVENT_MOTION_RESET = 6,
    VR_EVENT_CONNECTION_PROGRESS = 7,
} VREventType;

// Called on core worker threads (never the main thread). Must not call back into vr_session_* stop/destroy.
typedef struct VRCallbacks {
    void *user;
    // One complete Annex-B access unit (or codec-config NALs when is_config). Pointer valid only during the call.
    void (*video)(void *user, const uint8_t *annexb, size_t size, bool is_config, uint32_t width, uint32_t height,
                  int32_t frames_lost, bool recovered, uint64_t arrival_host_time /* mach_absolute_time */);
    // Interleaved S16 PCM, frames per channel. Pointer valid only during the call.
    void (*audio)(void *user, const int16_t *pcm, size_t frames, uint32_t channels, uint32_t rate);
    void (*event)(void *user, VREventType type, int32_t code, int32_t a, int32_t b);
    // DualSense adaptive trigger effect payloads (type byte + 10 data bytes each side), as sent by the console.
    void (*triggers)(void *user, uint8_t type_left, const uint8_t left[10], uint8_t type_right, const uint8_t right[10]);
    // DualSense haptics: stereo S16 PCM @ 3 kHz.
    void (*haptics)(void *user, const int16_t *pcm, size_t frames);
    void (*audio_timed)(void *user, const int16_t *pcm, size_t frames, uint32_t channels, uint32_t rate,
                        uint64_t first_sample, uint64_t arrival_host_time, bool discontinuity);
} VRCallbacks;

// Semantic buttons (same bit layout as Veyra ControllerState::Button).
enum {
    VR_BTN_CROSS = 1u << 0, VR_BTN_CIRCLE = 1u << 1, VR_BTN_SQUARE = 1u << 2, VR_BTN_TRIANGLE = 1u << 3,
    VR_BTN_LEFT = 1u << 4, VR_BTN_RIGHT = 1u << 5, VR_BTN_UP = 1u << 6, VR_BTN_DOWN = 1u << 7,
    VR_BTN_L1 = 1u << 8, VR_BTN_R1 = 1u << 9, VR_BTN_L3 = 1u << 10, VR_BTN_R3 = 1u << 11,
    VR_BTN_OPTIONS = 1u << 12, VR_BTN_SHARE = 1u << 13, VR_BTN_TOUCHPAD = 1u << 14, VR_BTN_PS = 1u << 15,
};

typedef struct VRTouch { int8_t id; uint16_t x, y; } VRTouch; // id -1 = no touch; x 0..1919, y 0..1079

typedef struct VRControllerState {
    uint32_t buttons;
    int16_t left_x, left_y, right_x, right_y; // chiaki convention: -32768..32767, +y = down
    uint8_t l2, r2;
    VRTouch touches[2];
    bool motion_valid;
    float gyro[3];   // rad/s, SDL frame
    float accel[3];  // g, SDL frame
    uint64_t motion_timestamp_us;
} VRControllerState;

typedef struct VRStats {
    bool connected;
    uint64_t video_units, audio_blocks, packets_received, packets_lost;
    uint64_t warnings, errors, idr_requests;
    int32_t last_quit_reason;
    int64_t server_target_bitrate;
} VRStats;

typedef struct VRSession VRSession;

// Returns 0 on success (chiaki_lib_init, once per process).
int32_t vr_init(void);

// Starts a session; host is IPv4 or hostname. Returns NULL on immediate failure (*error_out set).
VRSession *vr_session_start(const char *host, const VRCredentials *credentials, const VRVideoProfile *profile,
                            const VRCallbacks *callbacks, int32_t *error_out);
// Internet setup runs asynchronously; connection progress and failure use the callbacks.
VRSession *vr_session_start_psn(const char *access_token, const uint8_t console_uid[32],
                              const VRCredentials *credentials, const VRVideoProfile *profile,
                              const VRCallbacks *callbacks, int32_t *error_out);
typedef struct VRPSNDevice {
    uint8_t uid[32];
    char name[64];
    bool remote_play_enabled;
} VRPSNDevice;
int32_t vr_psn_list_devices(const char *access_token, VRPSNDevice *devices, int32_t max);
// Stops, joins and frees. Safe to call once from any non-callback thread.
void vr_session_stop(VRSession *session);
int32_t vr_session_request_idr(VRSession *session);
int32_t vr_session_set_controller(VRSession *session, const VRControllerState *state);
int32_t vr_session_set_login_pin(VRSession *session, const char *pin);
VRStats vr_session_stats(VRSession *session);

// Registration ("pairing"): blocking, run off the main thread. pin = 8-digit PIN shown on the PS5
// (Settings > System > Remote Play > Pair Device). account_id = 8-byte PSN account id.
typedef struct VRPairResult {
    int32_t error;            // 0 = success
    VRCredentials credentials;
    uint8_t console_mac[6];
    char nickname[64];
    char detail[192];         // console's rejection reason on failure (no secrets), else empty
} VRPairResult;
VRPairResult vr_pair_ps5(const char *host, const uint8_t account_id[8], const char *pin, uint32_t timeout_ms);

// LAN discovery (blocking up to timeout_ms). Fills up to max hosts; returns count or negative error.
typedef struct VRDiscoveredHost {
    char address[64];
    char host_id[32];
    char name[64];
    bool is_ps5;
    bool standby;
} VRDiscoveredHost;
int32_t vr_discover(VRDiscoveredHost *hosts, int32_t max, uint32_t timeout_ms);

// Wakes a console from rest mode using its regist key. Returns 0 on success.
int32_t vr_wakeup(const char *host, const char regist_key[16]);

// Diagnostics: everything below is read-only telemetry; nothing contains key material.

// Snapshot refreshed by the session thread every 100 ms (cheap to call at any rate).
typedef struct VRDiagnostics {
    bool valid;                  // false for a NULL/unknown session
    int32_t session_state;       // Veyra SessionState: 0 idle, 1 connecting, 2 waiting first frame,
                                 // 3 streaming, 4 login PIN, 5 failed, 6 stopping
    int32_t inbox_error;         // last SessionInbox failure code (2000+n = chiaki quit reason n)
    int32_t last_quit_reason, last_api_error;

    // Veyra VideoIngress (compressed AU queue between Chiaki and the delivery thread)
    uint64_t video_access_units, video_config_messages, video_accepted, video_consumed;
    uint64_t video_dropped, video_rejected, video_recoveries, video_idr_requests, video_epoch;
    uint32_t video_depth, video_high_water_depth;
    uint64_t video_bytes_queued, video_high_water_bytes;
    bool video_waiting_for_idr;

    // Veyra AudioIngress
    uint64_t audio_accepted, audio_consumed, audio_dropped, audio_rejected;
    double audio_buffered_ms;

    // SessionInbox
    uint64_t stale_callbacks, inbox_received_bytes, inbox_frames_lost, inbox_reference_recoveries;
    double received_fps, video_mbps; // trailing 1 s window

    // Chiaki session / backend
    uint64_t chiaki_video_callbacks, chiaki_audio_callbacks, callback_rejected;
    uint64_t packets_received, packets_lost;             // chiaki packet stats window
    uint64_t log_warnings, log_errors, log_infos;
    uint64_t transport_errors, assembly_errors;          // classified warning/error lines
    uint64_t fec_success, fec_failed, idr_retries, missing_reference_frames, corrupt_frame_reports;
    uint64_t metadata_frames_lost, metadata_recovered_frames, chiaki_video_bytes;
    int64_t server_target_bitrate;                       // -1 until reported (needs VERBOSE logs)
    uint64_t quality_reports;

    // Delivery thread (Chiaki callback -> C callback), trailing 256 samples, milliseconds
    uint64_t delivered_video_units, delivered_config_units, delivered_audio_blocks, idr_sent;
    double video_queue_latency_ms_p50, video_queue_latency_ms_p99, video_queue_latency_ms_max;
    double audio_queue_latency_ms_p50, audio_queue_latency_ms_p99;
    double video_callback_ms_p50, video_callback_ms_p99; // time spent inside the app's video callback
    uint64_t owner_wakeups, owner_idle_timeouts;

    // Takion v20 (chiaki patch 0111)
    int32_t takion_version;                              // 12 or 20 once connected, else 0
    bool takion_v20_offered;                             // false when v20 is off or fell back to 12
    uint64_t packets_received_total, packets_lost_total; // whole session (packets_* above are a window)
    uint32_t audio_source_channels;                      // console's channel count (>2 is down-mixed)
} VRDiagnostics;
VRDiagnostics vr_session_diagnostics(VRSession *session);

// Log levels (same bits as ChiakiLogLevel).
enum { VR_LOG_ERROR = 1u << 0, VR_LOG_WARNING = 1u << 1, VR_LOG_INFO = 1u << 2, VR_LOG_VERBOSE = 1u << 3, VR_LOG_DEBUG = 1u << 4 };
typedef void (*VRLogCallback)(void *user, int level, const char *line);
// Process-wide forwarding of chiaki session/discovery log lines (pairing logs are never forwarded).
// Lines are REDACTED: hexdumps, long hex/base64 runs and anything mentioning keys, registration,
// auth, PINs or accounts are dropped. level_mask 0 = VR_LOG_WARNING|VR_LOG_ERROR; VERBOSE/DEBUG
// take effect for sessions started afterwards (per-packet cost). Called on chiaki threads, never
// concurrently with or after a vr_set_log_callback(NULL, ...) returns. Pass NULL to disable.
void vr_set_log_callback(VRLogCallback callback, void *user, uint32_t level_mask);

#ifdef __cplusplus
}
#endif
#endif
