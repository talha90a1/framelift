// SPDX-License-Identifier: AGPL-3.0-only
// Low-latency hardware decoder: Annex-B access units -> VTDecompressionSession -> IOSurface 4:2:0 bi-planar frames.
// Threading: the VideoToolbox output handler must never flush or invalidate the session (deadlock).
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder {
    static let keyframeRequestInterval: Double = 0.2

    private let sink: FrameSink
    private let onNeedKeyframe: () -> Void
    private let onFirstFrame: () -> Void

    // MARK: Decode-side state (decodeLock)
    private let decodeLock = NSLock()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var hevc = false
    private var parameterSets: [UInt8: [UInt8]] = [:]
    private var parametersChanged = false
    private var dimensions = CMVideoDimensions(width: 0, height: 0)
    private var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private var waitingForIDR = true
    private var frameIndex: Int64 = 0
    /// Transport loss seen but not yet attached to a queued frame (config-only or dropped unit): the next
    /// queued frame carries the discontinuity.
    private var lossDiscontinuityPending = false

    // MARK: Shared state (stateLock): touched by the output handler
    private let stateLock = NSLock()
    private var epoch: UInt64 = 0
    private var recoveryRequested = false
    private var pendingDiscontinuity = true
    private var sequence: UInt64 = 0
    private var lastKeyframeRequest: UInt64 = 0
    /// Read the next delivered frame's colour tags (set per format change).
    private var colourPending = true
    private var colourTags = ColourTags.untagged
    /// Frames delivered; every 15th publishes decode time and source rate.
    private var decodedCount: UInt64 = 0
    private var decodeMs = Ring(capacity: 1024)
    private var arrivals = Ring(capacity: 64)

    init(sink: FrameSink, onNeedKeyframe: @escaping () -> Void, onFirstFrame: @escaping () -> Void) {
        self.sink = sink
        self.onNeedKeyframe = onNeedKeyframe
        self.onFirstFrame = onFirstFrame
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: Public API

    /// Any thread; serialised internally. Returns as soon as the frame is queued in VideoToolbox.
    func decode(_ unit: EncodedVideoUnit) {
        StreamRecorder.shared.append(unit)
        decodeLock.lock()
        let wantKeyframe = decodeLocked(unit)
        decodeLock.unlock()
        if wantKeyframe { onNeedKeyframe() }
    }

    // MARK: Decode path

    /// Returns true when the caller should invoke onNeedKeyframe (outside the lock).
    private func decodeLocked(_ unit: EncodedVideoUnit) -> Bool {
        let unitIsHEVC = unit.codec != .h264
        if unitIsHEVC != hevc {
            hevc = unitIsHEVC
            parameterSets.removeAll()
            format = nil
            destroySessionLocked()
            beginRecoveryLocked()
        }

        let bytes = [UInt8](unit.data)
        let nals = VideoAnnexB.split(bytes, hevc: hevc)
        var payload: [VideoAnnexB.NAL] = []
        var hasVCL = false, hasIDR = false
        for nal in nals {
            let t = nal.type
            if VideoAnnexB.isParameterSet(t, hevc: hevc) {
                let ps = Array(bytes[nal.range])
                if parameterSets[t] != ps {
                    parameterSets[t] = ps
                    parametersChanged = true
                }
            } else if VideoAnnexB.isDiscardable(t, hevc: hevc) {
                continue
            } else {
                payload.append(nal)
                if VideoAnnexB.isVCL(t, hevc: hevc) {
                    hasVCL = true
                    if VideoAnnexB.isIDR(t, hevc: hevc) { hasIDR = true }
                }
            }
        }

        var wantKeyframe = false

        // Transport loss is not a decoder reset: the console's recovery frames reference older pictures that
        // must survive, so keep decoding and only flag this unit's output frame as a discontinuity.
        if unit.framesLost > 0 || unit.recovered {
            lossDiscontinuityPending = true
        }

        stateLock.lock()
        let handlerError = recoveryRequested
        recoveryRequested = false
        stateLock.unlock()
        if handlerError {
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }  // flush
            beginRecoveryLocked()
            // A unit that is itself an IDR already recovers; don't ask the console for another.
            if !hasIDR { wantKeyframe = requestKeyframeIfAllowed() }
        }

        if parametersChanged, rebuildFormatLocked() {
            parametersChanged = false
        }

        guard hasVCL else { return wantKeyframe }  // config-only unit

        guard format != nil else { return requestKeyframeIfAllowed() || wantKeyframe }
        if waitingForIDR {
            guard hasIDR else { return requestKeyframeIfAllowed() || wantKeyframe }
            waitingForIDR = false
        }
        if session == nil && !createSessionLocked() {
            waitingForIDR = true
            return requestKeyframeIfAllowed() || wantKeyframe
        }
        switch submitLocked(
            bytes: bytes, nals: payload, arrival: unit.arrivalHostTime,
            discontinuity: lossDiscontinuityPending)
        {
        case .queued:
            lossDiscontinuityPending = false
            return wantKeyframe
        case .failed:
            return requestKeyframeIfAllowed() || wantKeyframe
        case .recoveryPending:
            // An error callback landed after the check above: redo this unit through the recovery path.
            return decodeLocked(unit) || wantKeyframe
        }
    }

    /// Flushes in-flight output (epoch bump), waits for IDR, flags the next delivered frame.
    private func beginRecoveryLocked() {
        waitingForIDR = true
        stateLock.lock()
        epoch &+= 1
        pendingDiscontinuity = true
        stateLock.unlock()
    }

    private func requestKeyframeIfAllowed() -> Bool {
        let now = HostClock.now()
        stateLock.lock(); defer { stateLock.unlock() }
        return claimKeyframeRequestStateLocked(now: now)
    }

    /// Rate limiter for onNeedKeyframe; caller holds stateLock and invokes the callback after unlocking.
    private func claimKeyframeRequestStateLocked(now: UInt64) -> Bool {
        if lastKeyframeRequest != 0 && HostClock.seconds(now &- lastKeyframeRequest) < Self.keyframeRequestInterval {
            return false
        }
        lastKeyframeRequest = now
        return true
    }

    /// Returns false while the parameter-set collection is still incomplete.
    private func rebuildFormatLocked() -> Bool {
        let order = VideoAnnexB.parameterSetTypes(hevc: hevc)
        let sets = order.compactMap { parameterSets[$0] }
        guard sets.count == order.count else { return false }
        guard let fmt = VideoAnnexB.makeFormatDescription(parameterSets: sets, hevc: hevc) else {
            return true  // unusable set: keep the old format, wait for the next config
        }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: fmt) { return true }

        let newDims = CMVideoFormatDescriptionGetDimensions(fmt)
        let depth = VideoAnnexB.lumaBitDepth(sps: sets[hevc ? 1 : 0], hevc: hevc)
        let tenBit = depth.map { $0 > 8 } ?? false
        // CoreMedia parses video_full_range_flag from the SPS VUI into this extension (absent = video range).
        let fullRange = (CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) ?? false
        let newPixelFormat =
            switch (tenBit, fullRange) {
            case (false, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case (false, true): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            case (true, false): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case (true, true): kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            }
        let hadFormat = format != nil
        let resized = hadFormat && (newDims.width != dimensions.width || newDims.height != dimensions.height)

        // Drain the old session before replacing it; never reuse it across a parameter-set change.
        destroySessionLocked()
        format = fmt
        dimensions = newDims
        pixelFormat = newPixelFormat
        beginRecoveryLocked()
        stateLock.lock(); colourPending = true; stateLock.unlock()
        if resized { sink.reset() }
        return true
    }

    private func createSessionLocked() -> Bool {
        guard let format else { return false }
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]
        let imageAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: Int(dimensions.width),
            kCVPixelBufferHeightKey: Int(dimensions.height),
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else { return false }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        return true
    }

    private func destroySessionLocked() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    private enum SubmitResult { case queued, failed, recoveryPending }

    private func submitLocked(
        bytes: [UInt8], nals: [VideoAnnexB.NAL], arrival: UInt64,
        discontinuity: Bool
    ) -> SubmitResult {
        guard let session, let format else { return .failed }
        let total = nals.reduce(0) { $0 + 4 + $1.range.count }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr, let block
        else { return .failed }
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                dataPointerOut: &dataPointer) == noErr, let dataPointer
        else { return .failed }
        bytes.withUnsafeBufferPointer { src in
            let dst = UnsafeMutableRawPointer(dataPointer)
            var off = 0
            for nal in nals {
                let len = UInt32(nal.range.count).bigEndian
                withUnsafeBytes(of: len) { dst.advanced(by: off).copyMemory(from: $0.baseAddress!, byteCount: 4) }
                dst.advanced(by: off + 4).copyMemory(from: src.baseAddress! + nal.range.lowerBound, byteCount: nal.range.count)
                off += 4 + nal.range.count
            }
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 1000),
            decodeTimeStamp: .invalid)
        frameIndex += 1
        var size = total
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample
        else { return .failed }

        let ticket = FrameTicket(arrival: arrival, submitted: HostClock.now(), discontinuity: discontinuity)
        // Read the epoch and the error flag in one critical section, so a frame predicted from a reference
        // that just failed is never tagged with the post-error epoch.
        stateLock.lock()
        if recoveryRequested { stateLock.unlock(); return .recoveryPending }
        ticket.epoch = epoch
        stateLock.unlock()

        var infoFlags = VTDecodeInfoFlags()
        // No _EnableTemporalProcessing: frames are emitted in decode order, never held for reordering.
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],  // not ._1xRealTimePlayback: it permits a slower low-power decode mode
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, imageBuffer, _, _ in
            self?.handleOutput(ticket: ticket, status: status, flags: flags, imageBuffer: imageBuffer)
        }
        guard status == noErr else {
            stateLock.lock(); ticket.done = true; stateLock.unlock()
            if status == kVTInvalidSessionErr {
                // System invalidated the session (sleep, GPU reset): rebuild on the next IDR.
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            } else {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
            beginRecoveryLocked()
            return .failed
        }
        return .queued
    }

    // MARK: Output (VideoToolbox thread)

    private func handleOutput(ticket: FrameTicket, status: OSStatus, flags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?) {
        let now = HostClock.now()
        stateLock.lock()
        if ticket.done { stateLock.unlock(); return }
        ticket.done = true

        if status != noErr {
            // Discard everything still in flight from this epoch; decode() flushes and waits for an IDR.
            var wantKeyframe = false
            if ticket.epoch == epoch {
                epoch &+= 1
                recoveryRequested = true
                pendingDiscontinuity = true
                wantKeyframe = claimKeyframeRequestStateLocked(now: now)
            }
            stateLock.unlock()
            if wantKeyframe { onNeedKeyframe() }
            return
        }
        guard let pixelBuffer = imageBuffer, !flags.contains(.frameDropped), ticket.epoch == epoch else {
            // A loss-flagged frame that produced no image: the next delivered frame takes the flag.
            if ticket.discontinuity && ticket.epoch == epoch { pendingDiscontinuity = true }
            stateLock.unlock()
            return
        }

        let discontinuity = pendingDiscontinuity || ticket.discontinuity
        pendingDiscontinuity = false
        let seq = sequence
        sequence += 1
        decodedCount += 1
        if colourPending {
            colourTags = ColourTags.read(pixelBuffer)
            colourPending = false
        }
        let tags = colourTags
        decodeMs.append(HostClock.milliseconds(from: ticket.submitted, to: now))
        arrivals.append(HostClock.seconds(ticket.arrival))
        var publish: (Double, Double)?
        if decodedCount % 15 == 0 {
            publish = (decodeMs.percentile(0.5, recent: 120), arrivals.rate())
        }
        stateLock.unlock()

        if let publish {
            Telemetry.shared.update {
                $0.decodeMsP50 = publish.0; $0.sourceFPS = publish.1
            }
        }
        Diagnostics.shared.mark(.arrival, sequence: seq, at: ticket.arrival)
        Diagnostics.shared.mark(.decoded, sequence: seq, at: now)
        sink.submit(
            DecodedFrame(
                pixelBuffer: pixelBuffer, sequence: seq, arrivalHostTime: ticket.arrival,
                decodedHostTime: now, discontinuity: discontinuity, colourTags: tags))
        if seq == 0 { onFirstFrame() }
    }

    // MARK: Helpers

    private final class FrameTicket {
        let arrival: UInt64
        let submitted: UInt64
        /// Transport loss before this unit: flag its output frame (not whichever frame is delivered next).
        let discontinuity: Bool
        var epoch: UInt64 = 0
        var done = false  // guarded by stateLock
        init(arrival: UInt64, submitted: UInt64, discontinuity: Bool) {
            self.arrival = arrival; self.submitted = submitted; self.discontinuity = discontinuity
        }
    }

    /// Fixed-size ring of doubles (guarded by stateLock).
    private struct Ring {
        private var values: [Double]
        private var next = 0
        private(set) var count = 0

        init(capacity: Int) { values = Array(repeating: 0, count: capacity) }

        mutating func append(_ v: Double) {
            values[next] = v
            next = (next + 1) % values.count
            count = min(count + 1, values.count)
        }

        func recent(_ n: Int) -> [Double] {
            let k = min(n, count)
            return (0..<k).map { values[(next - k + $0 + values.count) % values.count] }
        }

        func percentile(_ p: Double, recent n: Int = .max) -> Double {
            let v = recent(n).sorted()
            guard !v.isEmpty else { return 0 }
            return v[min(v.count - 1, Int((Double(v.count - 1) * p).rounded()))]
        }

        /// Events per second over the stored timestamps (seconds).
        func rate() -> Double {
            let v = recent(count)
            guard v.count >= 2, let first = v.first, let last = v.last, last > first else { return 0 }
            return Double(v.count - 1) / (last - first)
        }
    }
}
