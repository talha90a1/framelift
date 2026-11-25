// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import FrameliftCore
@testable import Framelift

struct CoreDiagnosticsTests {
    @Test func labelsIsolatedStallsSeparatelyFromPercentiles() {
        var diagnostics = VRDiagnostics()
        diagnostics.video_queue_latency_ms_p50 = 0.1
        diagnostics.video_queue_latency_ms_p99 = 0.2
        diagnostics.video_queue_latency_ms_max = 8.6
        diagnostics.video_callback_ms_p50 = 0.8
        diagnostics.video_callback_ms_p99 = 2.5
        diagnostics.video_callback_ms_max = 155.5
        diagnostics.audio_queue_latency_ms_p50 = 0.03
        diagnostics.audio_queue_latency_ms_p99 = 44.5
        diagnostics.audio_queue_latency_ms_max = 99.9
        diagnostics.owner_loop_gap_ms_max = 170.8
        let line = CoreDiagnostics.line(diagnostics)
        #expect(line.contains("vq-ms[p50/p99/max]=0.10/0.20/8.60"))
        #expect(line.contains("cb-ms[p50/p99/max]=0.80/2.50/155.50"))
        #expect(line.contains("aq-ms[p50/p99/max]=0.03/44.50/99.90"))
        #expect(line.contains("owner-loop-gap-max=170.80ms"))
    }
}
