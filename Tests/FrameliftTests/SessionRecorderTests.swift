// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Framelift

struct SessionRecorderTests {
    @Test func movieContainsPlayableVideoAndAudio() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.mp4")
        let recorder = SessionRecorder(url: url)
        let width = 128, height = 72
        let data = Data(repeating: 128, count: width * height * 3 / 2)
        let frame = try #require(OfflineFrameGenHarness.makeBuffer(data, w: width, h: height))
        let start = HostClock.now()
        for index in 0..<30 {
            let time = HostClock.seconds(start) + Double(index) / 60
            recorder.appendVideo(frame, tags: .untagged, at: time)
            let samples = (0..<800).flatMap { offset -> [Int16] in
                let v = Int16(sin(Double(index * 800 + offset) * 2 * .pi * 440 / 48000) * 3000)
                return [v, v]
            }
            recorder.appendAudio(PCMChunk(samples: samples, channels: 2, sampleRate: 48000,
                firstSample: UInt64(index * 800), arrivalHostTime: start + HostClock.ticks(seconds: Double(index) / 60)), delayMs: 0)
            try await Task.sleep(for: .milliseconds(17))
        }
        let result = await withCheckedContinuation { continuation in recorder.finish { continuation.resume(returning: $0) } }
        _ = try result.get()
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1 && audio.count == 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try #require(video.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let sound = AVAssetReaderTrackOutput(track: try #require(audio.first), outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output); reader.add(sound)
        #expect(reader.startReading())
        var frames = 0, blocks = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        while sound.copyNextSampleBuffer() != nil { blocks += 1 }
        #expect(frames >= 20 && blocks > 0)
        #expect(reader.status == .completed)
    }
}
