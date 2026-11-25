// SPDX-License-Identifier: AGPL-3.0-only
// Core (Veyra C++ + chiaki-ng) visibility: redacted chiaki log forwarding and the per-second
// "core ..." line written to Diagnostics.shared while a session streams.
import Foundation
import VeyraCore

enum CoreDiagnostics {
    /// Forwards redacted chiaki log lines (the core drops anything that could carry keys) into
    /// Diagnostics events: warning+error, plus info while Diagnostics is enabled ("Debug logs").
    /// Called at each session start.
    static func installLogForwarding() {
        let base = UInt32(VR_LOG_ERROR | VR_LOG_WARNING)
        vr_set_log_callback(logCallback, nil, Diagnostics.shared.enabled ? base | UInt32(VR_LOG_INFO) : base)
    }

    private static let logCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void = {
        _, level, line in
        guard let line else { return }
        let tag = switch UInt32(level) {
        case UInt32(VR_LOG_ERROR): "E"
        case UInt32(VR_LOG_WARNING): "W"
        case UInt32(VR_LOG_INFO): "I"
        case UInt32(VR_LOG_VERBOSE): "V"
        default: "D"
        }
        Diagnostics.shared.event("chiaki[\(tag)] \(String(cString: line))")
    }

    static func isStreaming(_ d: VRDiagnostics) -> Bool { d.valid && (d.session_state == 2 || d.session_state == 3) }

    /// One compact line; deltas are the caller's job (counters here are cumulative).
    static func line(_ d: VRDiagnostics) -> String {
        String(
            format: "core st=%d rx=%.0ffps %.1fMbps pkt=%llu/%llu lost fec=%llu ok/%llu fail idr=%llu sent/%llu retry"
                + " vq=%u/%u hw drop=%llu rej=%llu rec=%llu waitIdr=%d lost=%llu missRef=%llu corrupt=%llu"
                + " vq-ms[p50/p99/max]=%.2f/%.2f/%.2f cb-ms[p50/p99/max]=%.2f/%.2f/%.2f aq-ms[p50/p99/max]=%.2f/%.2f/%.2f abuf=%.0fms adrop=%llu"
                + " warn=%llu err=%llu xport=%llu asm=%llu stale=%llu tgt=%lld wake=%llu idle=%llu"
                + " tk=%d pktTotal=%llu/%llu lost ach=%u owner-loop-gap-max=%.2fms",
            d.session_state, d.received_fps, d.video_mbps, d.packets_received, d.packets_lost,
            d.fec_success, d.fec_failed, d.idr_sent, d.idr_retries,
            d.video_depth, d.video_high_water_depth, d.video_dropped, d.video_rejected, d.video_recoveries,
            Int32(d.video_waiting_for_idr ? 1 : 0), d.metadata_frames_lost, d.missing_reference_frames, d.corrupt_frame_reports,
            d.video_queue_latency_ms_p50, d.video_queue_latency_ms_p99, d.video_queue_latency_ms_max,
            d.video_callback_ms_p50, d.video_callback_ms_p99, d.video_callback_ms_max,
            d.audio_queue_latency_ms_p50, d.audio_queue_latency_ms_p99, d.audio_queue_latency_ms_max,
            d.audio_buffered_ms, d.audio_dropped,
            d.log_warnings, d.log_errors, d.transport_errors, d.assembly_errors, d.stale_callbacks,
            d.server_target_bitrate, d.owner_wakeups, d.owner_idle_timeouts,
            d.takion_version, d.packets_received_total, d.packets_lost_total, d.audio_source_channels,
            d.owner_loop_gap_ms_max
        )
    }
}
