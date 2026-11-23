// SPDX-License-Identifier: AGPL-3.0-only
// Loopback lifecycle test for the VeyraCore bridge, meant to run under ASan/UBSan and TSan
// (Tests/core_sanitize.sh). No PS5 is contacted: sessions target 127.0.0.1, where the session
// request is refused, so this exercises start -> chiaki threads -> quit event -> stop/join while
// other threads hammer the session API, plus log forwarding and diagnostics.
#include "VeyraBridge.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static atomic_int g_events, g_quits, g_log_lines;
static atomic_bool g_hammer;

static void on_event(void *user, VREventType type, int32_t code, int32_t a, int32_t b) {
    (void)user; (void)a; (void)b;
    atomic_fetch_add(&g_events, 1);
    if (type == VR_EVENT_QUIT || type == VR_EVENT_FAILED) atomic_fetch_add(&g_quits, 1);
    (void)code;
}

static void on_log(void *user, int level, const char *line) {
    (void)user;
    if (atomic_fetch_add(&g_log_lines, 1) < 6) printf("  log[%d] %s\n", level, line);
}

static void *hammer(void *arg) {
    VRSession *s = (VRSession *)arg;
    VRControllerState st;
    memset(&st, 0, sizeof st);
    uint64_t t = 1;
    while (atomic_load(&g_hammer)) {
        st.buttons ^= VR_BTN_CROSS;
        st.motion_valid = true;
        st.motion_timestamp_us = t += 1000;
        st.gyro[0] = 0.1f; st.accel[1] = 1.0f;
        vr_session_set_controller(s, &st);
        vr_session_request_idr(s);
        vr_session_set_login_pin(s, "1234");
        VRStats x = vr_session_stats(s);
        VRDiagnostics d = vr_session_diagnostics(s);
        (void)x; (void)d;
        usleep(200);
    }
    return NULL;
}

int main(int argc, char **argv) {
    int cycles = argc > 1 ? atoi(argv[1]) : 20;
    vr_set_log_callback(on_log, NULL, VR_LOG_ERROR | VR_LOG_WARNING | VR_LOG_INFO);
    if (vr_init() != 0) return 1;
    VRCredentials cr;
    memset(&cr, 0, sizeof cr);
    memcpy(cr.regist_key, "0123abcd", 8);
    VRVideoProfile p = {1920, 1080, 60, 15000, VR_CODEC_H265};
    VRCallbacks cb;
    memset(&cb, 0, sizeof cb);
    cb.event = on_event;
    for (int i = 0; i < cycles; ++i) {
        int32_t err = 0;
        VRSession *s = vr_session_start("127.0.0.1", &cr, &p, &cb, &err);
        if (!s) { printf("cycle %d: start failed %d\n", i, err); return 2; }
        atomic_store(&g_hammer, true);
        pthread_t threads[3];
        for (int k = 0; k < 3; ++k) pthread_create(&threads[k], NULL, hammer, s);
        usleep(i % 3 == 0 ? 1000 : 300000); // some cycles stop before chiaki reports the quit
        atomic_store(&g_hammer, false);
        for (int k = 0; k < 3; ++k) pthread_join(threads[k], NULL);
        VRDiagnostics d = vr_session_diagnostics(s);
        if (i == cycles - 1)
            printf("last diagnostics: valid=%d state=%d inbox_error=%d quit=%d warnings=%llu errors=%llu infos=%llu wakeups=%llu idle=%llu\n",
                   d.valid, d.session_state, d.inbox_error, d.last_quit_reason, d.log_warnings, d.log_errors,
                   d.log_infos, d.owner_wakeups, d.owner_idle_timeouts);
        vr_session_stop(s);
    }
    VRDiscoveredHost hosts[4];
    int32_t n = vr_discover(hosts, 4, 1000);
    vr_set_log_callback(NULL, NULL, 0);
    printf("cycles=%d events=%d quits/failures=%d forwarded_log_lines=%d discover=%d\n", cycles,
           atomic_load(&g_events), atomic_load(&g_quits), atomic_load(&g_log_lines), n);
    return 0;
}
