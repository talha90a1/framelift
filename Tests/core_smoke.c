// SPDX-License-Identifier: AGPL-3.0-only
// Link + init smoke test for VeyraCore: vr_init() then a 2 s LAN discovery.
// Build: see Tests/core_smoke.sh
#include "VeyraBridge.h"
#include <stdio.h>
#include <arpa/inet.h>
#include <chiaki/remote/holepunch.h>

int main(void) {
    int32_t init = vr_init();
    printf("vr_init() = %d\n", init);
    if (init != 0) return 1;
    if(vr_psn_list_devices(NULL, NULL, 0) >= 0) return 3;
    int32_t error = 0;
    if(vr_session_start_psn(NULL, NULL, NULL, NULL, NULL, &error) != NULL || error == 0) return 4;
    ChiakiLog log;
    chiaki_log_init(&log, 0, NULL, NULL);
    for(int i = 0; i < 100; ++i) {
        ChiakiHolepunchSession session = chiaki_holepunch_session_init("fixture-token", &log);
        if(!session) return 5;
        chiaki_holepunch_main_thread_cancel(session, true);
        chiaki_holepunch_session_fini(session);
    }
    VRDiscoveredHost hosts[16];
    int32_t count = vr_discover(hosts, 16, 2000);
    printf("vr_discover(2000 ms) = %d\n", count);
    for (int32_t i = 0; i < count; ++i)
        printf("  %s %s name=\"%s\" ps5=%d standby=%d\n", hosts[i].address, hosts[i].host_id, hosts[i].name,
               hosts[i].is_ps5, hosts[i].standby);
    return count < 0 ? 2 : 0;
}
