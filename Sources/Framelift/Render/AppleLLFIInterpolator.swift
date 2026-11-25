// SPDX-License-Identifier: AGPL-3.0-only
// "Apple ML interpolation": VideoToolbox low-latency frame interpolation (one mid frame per pair).
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct InterpolationResult: @unchecked Sendable {
    /// The generated mid frame (t = 0.5), retaining the input bit depth; empty on failure.
    var frames: [CVPixelBuffer]
    /// Wall time from the call to the completion, ms.
    var wallMs: Double
    var error: String?
}

protocol FrameInterpolator: AnyObject, Sendable {
    var backendName: String { get }
    func isReady(for buffer: CVPixelBuffer) -> Bool
    func prepare(width: Int, height: Int)
    func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer, completion: @escaping (InterpolationResult) -> Void)
    func reset()
}

/// VTFrameProcessor + VTLowLatencyFrameInterpolation (macOS 26+). One request in flight at a
/// time; a request while busy fails immediately (the pacer shows the real frame instead).
final class AppleLLFIInterpolator: FrameInterpolator, @unchecked Sendable {
    var backendName: String { "Apple ML interpolation" }

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    private final class Session {
        let processor: VTFrameProcessor
        let pool: CVPixelBufferPool
        var busy = false
        var ptsCounter: Int64 = 0

        private let setupQueue: DispatchQueue

        init(processor: VTFrameProcessor, pool: CVPixelBufferPool, setupQueue: DispatchQueue) {
            self.processor = processor
            self.pool = pool
            self.setupQueue = setupQueue
        }

        deinit {
            // The last reference can go away on VideoToolbox's own callback queue.
            setupQueue.async { [processor] in processor.endSession() }
        }

        func makeParameters(previous: CVPixelBuffer, current: CVPixelBuffer)
            -> (VTLowLatencyFrameInterpolationParameters, CVPixelBuffer)?
        {
            var mid: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &mid)
            guard let mid else { return nil }
            ptsCounter += 2
            let t = ptsCounter
            guard let src = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: CMTime(value: t, timescale: 60)),
                let prev = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: CMTime(value: t - 2, timescale: 60)),
                let dst = VTFrameProcessorFrame(buffer: mid, presentationTimeStamp: CMTime(value: t - 1, timescale: 60))
            else { return nil }
            guard
                let params = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: src, previousFrame: prev, interpolationPhase: [0.5], destinationFrames: [dst])
            else { return nil }
            return (params, mid)
        }

        func warmUp(with source: CVPixelBuffer, count: Int) {
            for _ in 0..<count {
                guard let (params, _) = makeParameters(previous: source, current: source) else { return }
                let done = DispatchSemaphore(value: 0)
                processor.process(parameters: params) { _, _ in done.signal() }
                if done.wait(timeout: .now() + 5) == .timedOut { return }
            }
        }
    }

    private let lock = NSLock()
    private let setupQueue = DispatchQueue(label: "framelift.vt-interp.setup", qos: .userInitiated)
    private var session: Session?
    private var configuredSize: (Int, Int)?
    private var preparingSize: (Int, Int)?
    private let keepWarm: Bool
    private var warmSession: Session?
    /// Host time (s) of the last real request and the smoothed spacing between requests.
    private var lastRequest: Double = 0
    private var requestInterval: Double = 0
    /// Last warm request's duration (s): it is skipped when it would still run at the next real one.
    private var warmDuration: Double = 0.012
    private var generation = 0

    init(keepWarm: Bool = true) {
        self.keepWarm = keepWarm
    }

    func isReady(for buffer: CVPixelBuffer) -> Bool {
        lock.withLock { session != nil && isReadyLocked(buffer) }
    }

    func prepare(width: Int, height: Int) {
        lock.lock()
        if let s = configuredSize, s == (width, height) { lock.unlock(); return }
        if let s = preparingSize, s == (width, height) { lock.unlock(); return }
        preparingSize = (width, height)
        generation += 1
        let gen = generation
        lock.unlock()
        setupQueue.async { [weak self] in self?.configure(width: width, height: height, generation: gen) }
    }

    private func configure(width: Int, height: Int, generation gen: Int) {
        guard Self.isSupported,
            let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1)
        else {
            NSLog("[render] VT LLFI unsupported for %dx%d", width, height)
            return
        }
        guard let primary = makeSession(config, bufferCount: 6) else { return }
        var warm: Session?
        if let source = Self.blankSource(cfg: config, width: width, height: height) {
            primary.warmUp(with: source, count: 2)
            if keepWarm, let secondary = makeSession(config, bufferCount: 2) {
                secondary.warmUp(with: source, count: 1)
                warm = secondary
            }
        }

        lock.withLock {
            guard gen == generation else { return }
            session = primary
            warmSession = warm
            configuredSize = (width, height)
            preparingSize = nil
        }
    }

    private func makeSession(_ config: VTLowLatencyFrameInterpolationConfiguration, bufferCount: Int) -> Session? {
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: config)
        } catch {
            NSLog("[render] VT LLFI startSession failed: %@", "\(error)")
            return nil
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: bufferCount] as CFDictionary,
            config.destinationPixelBufferAttributes as CFDictionary, &pool)
        guard let pool else {
            processor.endSession()
            return nil
        }
        return Session(processor: processor, pool: pool, setupQueue: setupQueue)
    }

    private static func blankSource(cfg: VTLowLatencyFrameInterpolationConfiguration, width: Int, height: Int) -> CVPixelBuffer? {
        var attrs = cfg.sourcePixelBufferAttributes
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        attrs[kCVPixelBufferPixelFormatTypeKey as String] = PixelFormats.videoRange420
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, PixelFormats.videoRange420, attrs as CFDictionary, &pb)
        return pb
    }

    /// Asynchronous; `completion` runs on an arbitrary thread, exactly once.
    func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer, completion: @escaping (InterpolationResult) -> Void) {
        run(previous: previous, current: current, start: HostClock.now(), completion: completion)
    }

    /// Throw-away request on the last pair on the warm session, right after a real one finishes;
    /// skipped when it would still be running when the next real request is due.
    private func warm(previous: CVPixelBuffer, current: CVPixelBuffer, after primary: Session) {
        let now = HostClock.seconds(HostClock.now())
        lock.lock()
        let nextDue = lastRequest + requestInterval
        guard session === primary, !primary.busy, requestInterval > 0, now + warmDuration + 0.002 < nextDue,
            let warmSession, !warmSession.busy,
            let (params, _) = warmSession.makeParameters(previous: previous, current: current)
        else {
            lock.unlock()
            return
        }
        warmSession.busy = true
        lock.unlock()
        warmSession.processor.process(parameters: params) { [weak self, weak warmSession] _, _ in
            guard let self, let warmSession else { return }
            let took = HostClock.seconds(HostClock.now()) - now
            self.lock.withLock {
                warmSession.busy = false
                self.warmDuration += (min(took, 0.03) - self.warmDuration) * 0.2
            }
        }
        withExtendedLifetime(warmSession) {}
    }

    private func run(previous: CVPixelBuffer, current: CVPixelBuffer, start: UInt64, completion: @escaping (InterpolationResult) -> Void) {
        lock.lock()
        guard let session, !session.busy, isReadyLocked(current), isReadyLocked(previous) else {
            let why = session?.busy == true ? "busy" : "not ready"
            lock.unlock()
            completion(InterpolationResult(frames: [], wallMs: 0, error: why))
            return
        }
        guard let (params, mid) = session.makeParameters(previous: previous, current: current) else {
            lock.unlock()
            completion(InterpolationResult(frames: [], wallMs: 0, error: "parameters"))
            return
        }
        session.busy = true
        let t = HostClock.seconds(start)
        if lastRequest > 0 {
            let d = t - lastRequest
            if d > 0.005 && d < 0.1 { requestInterval = requestInterval == 0 ? d : requestInterval + (d - requestInterval) * 0.1 }
        }
        lastRequest = t
        lock.unlock()
        session.processor.process(parameters: params) { [weak self, weak session] _, error in
            self?.lock.withLock { session?.busy = false }
            let ms = HostClock.milliseconds(from: start, to: HostClock.now())
            if let error {
                completion(InterpolationResult(frames: [], wallMs: ms, error: "\(error)"))
            } else {
                completion(InterpolationResult(frames: [mid], wallMs: ms, error: nil))
                if let session { self?.warm(previous: previous, current: current, after: session) }
            }
        }
        withExtendedLifetime(session) {}
    }

    private func isReadyLocked(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == PixelFormats.videoRange420, let s = configuredSize else { return false }
        return s.0 == CVPixelBufferGetWidth(buffer) && s.1 == CVPixelBufferGetHeight(buffer)
    }

    func reset() {
        lock.withLock {
            session?.ptsCounter = 0
            warmSession?.ptsCounter = 0
        }
    }
}
