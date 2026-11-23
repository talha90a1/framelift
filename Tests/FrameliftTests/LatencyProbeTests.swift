// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Testing
@testable import Framelift

private final class NullController: ControllerSink { var sent = 0; func send(_ state: ControllerSnapshot) { sent += 1 } }
private final class NullFrames: FrameSink { var got = 0; func submit(_ frame: DecodedFrame) { got += 1 }; func reset() {} }

private func frame(luma: UInt8, seq: UInt64, arrival: UInt64) -> DecodedFrame {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
    let buffer = pb!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    memset(base, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 72)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return DecodedFrame(pixelBuffer: buffer, sequence: seq, arrivalHostTime: arrival, decodedHostTime: arrival, discontinuity: false)
}

struct LatencyProbeTests {
    @Test func measuresPressToFirstBigPictureChange() {
        let c = NullController(), f = NullFrames()
        let status = ProbeStatus()
        let probe = LatencyProbe(controller: c, frames: f, status: status)
        #expect(probe.toggle())
        let t0 = HostClock.now()
        probe.submit(frame(luma: 100, seq: 0, arrival: t0))
        probe.submit(frame(luma: 101, seq: 1, arrival: t0 + HostClock.ticks(seconds: 0.033)))
        var pressed = ControllerSnapshot(); pressed.buttons = [.options]
        probe.send(pressed) // press stamped now
        let press = HostClock.now()
        probe.submit(frame(luma: 102, seq: 2, arrival: press + HostClock.ticks(seconds: 0.040))) // small change: ignored
        probe.submit(frame(luma: 30, seq: 3, arrival: press + HostClock.ticks(seconds: 0.080)))  // pause menu
        let text = status.text ?? ""
        #expect(text.contains("round trip"))
        #expect(text.contains("of 1"))
        #expect(c.sent == 1 && f.got == 4) // everything still forwarded
        #expect(!probe.toggle())
        #expect(status.text == nil)
    }
}
