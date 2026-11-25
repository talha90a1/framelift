// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import Testing
@testable import Framelift

struct AudioRingTests {
    @Test func underrunReprimesAndFlushDropsOldSoundOnTheConsumer() throws {
        let ring = AudioRing(capacityFrames: 4096)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let samples = [Int16](repeating: 12000, count: 1200)
        samples.withUnsafeBufferPointer { ring.write(interleavedS16: $0, channels: 2) }
        var silence: ObjCBool = false
        func render() {
            ring.render(into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: 256,
                        isSilence: &silence, prefill: 400, target: 400, maxFrames: 800)
        }
        render()
        #expect(!silence.boolValue)
        render()
        #expect(ring.underruns.load(ordering: .relaxed) == 1)
        render()
        #expect(silence.boolValue)
        #expect(buffer.floatChannelData![0][255] == 0)
        samples.withUnsafeBufferPointer { ring.write(interleavedS16: $0, channels: 2) }
        ring.flushRequested.store(true, ordering: .releasing)
        render()
        #expect(silence.boolValue)
        #expect(ring.readIndex.load(ordering: .acquiring) == ring.writeIndex.load(ordering: .acquiring))
    }
}
