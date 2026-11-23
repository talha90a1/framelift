// SPDX-License-Identifier: AGPL-3.0-only
// Link + init smoke test for VeyraCore: vr_init() then a 2 s LAN discovery.
// Build: see Tests/core_smoke.sh
#include "VeyraBridge.h"
#include <stdio.h>

int main(void) {
    int32_t init = vr_init();
    printf("vr_init() = %d\n", init);
    if (init != 0) return 1;
    VRDiscoveredHost hosts[16];
    int32_t count = vr_discover(hosts, 16, 2000);
    printf("vr_discover(2000 ms) = %d\n", count);
    for (int32_t i = 0; i < count; ++i)
        printf("  %s %s name=\"%s\" ps5=%d standby=%d\n", hosts[i].address, hosts[i].host_id, hosts[i].name,
               hosts[i].is_ps5, hosts[i].standby);
    return count < 0 ? 2 : 0;
}
