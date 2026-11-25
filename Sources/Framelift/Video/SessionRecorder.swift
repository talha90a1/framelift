// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

final class SessionRecorder: @unchecked Sendable {
    let url: URL
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "framelift.recording", qos: .utility)
    private let pending = Atomic<Int>(0)
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var pixels: AVAssetWriterInputPixelBufferAdaptor?
    private var origin: Double?
    private var lastVideo = CMTime.invalid
    private var lastAudio = CMTime.invalid
    private var audioAnchor: (sample: UInt64, host: Double)?
    private var earlyAudio: [(PCMChunk, Double)] = []
    private var stopped = false
    private var failure: Error?
    private var size: (Int, Int)?
    private var hdr: Bool?
    private var dropped = 0

    init(url: URL) { self.url = url }

    func appendVideo(_ frame: CVPixelBuffer, tags: ColourTags, at hostTime: Double) {
        guard pending.add(1, ordering: .relaxed).newValue <= 8 else {
            pending.subtract(1, ordering: .relaxed)
            return
        }
        queue.async { [self] in
            defer { pending.subtract(1, ordering: .relaxed) }
            guard !stopped else { return }
            do {
                if writer == nil { try begin(frame, tags: tags, at: hostTime) }
                guard size?.0 == CVPixelBufferGetWidth(frame), size?.1 == CVPixelBufferGetHeight(frame), hdr == (tags.hdrCurve != nil) else {
                    throw RecordingError.formatChanged
                }
                let time = CMTime(seconds: hostTime - origin!, preferredTimescale: 60000)
                guard time >= .zero, !lastVideo.isValid || time > lastVideo else { return }
                guard video?.isReadyForMoreMediaData == true else { dropped += 1; return }
                guard pixels?.append(frame, withPresentationTime: time) == true else { throw writer?.error ?? RecordingError.writeFailed }
                lastVideo = time
                let waiting = earlyAudio
                earlyAudio.removeAll()
                for (chunk, delay) in waiting { try writeAudio(chunk, delay: delay) }
            } catch { fail(error) }
        }
    }

    func appendAudio(_ chunk: PCMChunk, delayMs: Double) {
        guard pending.add(1, ordering: .relaxed).newValue <= 12 else {
            pending.subtract(1, ordering: .relaxed)
            return
        }
        queue.async { [self] in
            defer { pending.subtract(1, ordering: .relaxed) }
            guard !stopped else { return }
            if writer == nil {
                earlyAudio.append((chunk, delayMs))
                if earlyAudio.count > 100 { earlyAudio.removeFirst() }
                return
            }
            do { try writeAudio(chunk, delay: delayMs) }
            catch { fail(error) }
        }
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            stopped = true
            earlyAudio.removeAll()
            guard let writer else { completion(.failure(failure ?? RecordingError.noFrames)); return }
            if writer.status == .writing {
                video?.markAsFinished()
                audio?.markAsFinished()
                writer.finishWriting {
                    if let failure = self.failure { completion(.failure(failure)) }
                    else if writer.status == .completed { completion(.success(self.url)) }
                    else { completion(.failure(writer.error ?? RecordingError.writeFailed)) }
                }
            } else { completion(.failure(failure ?? writer.error ?? RecordingError.writeFailed)) }
            if dropped > 0 { Diagnostics.shared.event("recording: \(dropped) video frames skipped by the encoder") }
        }
    }

    private func begin(_ frame: CVPixelBuffer, tags: ColourTags, at hostTime: Double) throws {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let isHDR = tags.hdrCurve != nil
        var compression: [String: Any] = [AVVideoAverageBitRateKey: width * height * 12,
            AVVideoExpectedSourceFrameRateKey: 60, AVVideoMaxKeyFrameIntervalKey: 60]
        if isHDR { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression]
        var color: [String: Any] = [:]
        if let p = tags.primaries { color[AVVideoColorPrimariesKey] = p }
        if let t = tags.transfer { color[AVVideoTransferFunctionKey] = t }
        if let m = tags.matrix { color[AVVideoYCbCrMatrixKey] = m }
        if !color.isEmpty { settings[AVVideoColorPropertiesKey] = color }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw RecordingError.writeFailed }
        writer.add(video); writer.add(audio)
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(frame),
                                         kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writeFailed }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.video = video; self.audio = audio; self.pixels = pixels
        origin = hostTime; size = (width, height); hdr = isHDR
    }

    private func writeAudio(_ chunk: PCMChunk, delay: Double) throws {
        guard let origin, chunk.channels == 2, chunk.sampleRate == 48000, !chunk.samples.isEmpty else { return }
        let arrival = HostClock.seconds(chunk.arrivalHostTime > 0 ? chunk.arrivalHostTime : HostClock.now())
        if audioAnchor == nil || chunk.discontinuity || chunk.firstSample < audioAnchor!.sample {
            audioAnchor = (chunk.firstSample, arrival)
        }
        let anchor = audioAnchor!
        let host = anchor.host + Double(chunk.firstSample - anchor.sample) / 48000 + delay / 1000
        let time = CMTime(seconds: host - origin, preferredTimescale: 48000)
        guard time >= .zero, !lastAudio.isValid || time > lastAudio else { return }
        guard audio?.isReadyForMoreMediaData == true else { return }
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
            let description else { throw RecordingError.writeFailed }
        let bytes = chunk.samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
            blockBufferOut: &block) == noErr, let block else { throw RecordingError.writeFailed }
        let copied = chunk.samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard copied == noErr else { throw RecordingError.writeFailed }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
            sampleCount: chunk.samples.count / 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample, audio?.append(sample) == true else { throw writer?.error ?? RecordingError.writeFailed }
        lastAudio = time
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        stopped = true
        onError?(error.localizedDescription)
    }

    enum RecordingError: LocalizedError {
        case noFrames, writeFailed, formatChanged
        var errorDescription: String? {
            switch self {
            case .noFrames: "No video frames were recorded."
            case .writeFailed: "Couldn't write the recording. Check the available disk space."
            case .formatChanged: "Recording stopped because the video format changed. Start a new recording to continue."
            }
        }
    }
}

final class RecordingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: SessionRecorder?
    private var latest: CVPixelBuffer?
    var onError: ((String) -> Void)?

    func start(url: URL) {
        let recorder = SessionRecorder(url: url)
        recorder.onError = { [weak self, weak recorder] message in
            DispatchQueue.main.async {
                guard let self, let recorder else { return }
                let callback = self.lock.withLock { self.recorder === recorder ? self.onError : nil }
                callback?(message)
            }
        }
        lock.withLock { self.recorder = recorder }
    }

    func video(_ frame: CVPixelBuffer, tags: ColourTags, at time: Double) {
        let target = lock.withLock { latest = frame; return recorder }
        target?.appendVideo(frame, tags: tags, at: time)
    }

    func audio(_ chunk: PCMChunk, delayMs: Double) {
        lock.withLock { recorder }?.appendAudio(chunk, delayMs: delayMs)
    }

    func stop(_ completion: @escaping (Result<URL, Error>) -> Void = { _ in }) {
        let target = lock.withLock { let old = recorder; recorder = nil; return old }
        target?.finish(completion)
    }

    func screenshot(to url: URL) throws {
        guard let frame = lock.withLock({ latest }) else { throw SessionRecorder.RecordingError.noFrames }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: frame), to: url,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
