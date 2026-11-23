// SPDX-License-Identifier: AGPL-3.0-only
// "Apple ML interpolation": VideoToolbox low-latency frame interpolation (one mid frame per pair).
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct InterpolationResult {
    /// The generated mid frame (t = 0.5) as an 8-bit 420v IOSurface buffer; empty on failure.
    var frames: [CVPixelBuffer]
    /// Wall time from the call to the completion, ms.
    var wallMs: Double
    var error: String?
}

/// VTFrameProcessor + VTLowLatencyFrameInterpolation (macOS 26+). One request in flight at a
/// time; a request while busy fails immediately (the pacer shows the real frame instead).
final class AppleLLFIInterpolator: @unchecked Sendable {
    var backendName: String { "Apple ML interpolation" }

    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    private let lock = NSLock()
    private let setupQueue = DispatchQueue(label: "framelift.vt-interp.setup", qos: .userInitiated)
    private var processor: VTFrameProcessor?
    private var pool: CVPixelBufferPool?
    private var configuredSize: (Int, Int)?
    private var preparingSize: (Int, Int)?
    private var busy = false
    // Keep-warm: a request after a short idle runs markedly slower, so a throw-away request runs
    // on a second session right after each real one; a real request never waits for it.
    private let keepWarm: Bool
    private var warmProcessor: VTFrameProcessor?
    private var warmPool: CVPixelBufferPool?
    private var warmBusy = false
    /// Host time (s) of the last real request and the smoothed spacing between requests.
    private var lastRequest: Double = 0
    private var requestInterval: Double = 0
    /// Last warm request's duration (s): it is skipped when it would still run at the next real one.
    private var warmDuration: Double = 0.012
    private var generation = 0
    private var ptsCounter: Int64 = 0

    init(keepWarm: Bool = true) {
        self.keepWarm = keepWarm
    }

    deinit {
        processor?.endSession()
        warmProcessor?.endSession()
    }

    func isReady(for buffer: CVPixelBuffer) -> Bool {
        lock.withLock { processor != nil && isReadyLocked(buffer) }
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
              let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else {
            NSLog("[render] VT LLFI unsupported for %dx%d", width, height)
            return
        }
        let proc = VTFrameProcessor()
        do { try proc.startSession(configuration: cfg) } catch {
            NSLog("[render] VT LLFI startSession failed: %@", "\(error)")
            return
        }
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                cfg.destinationPixelBufferAttributes as CFDictionary, &pool)
        guard let pool else { proc.endSession(); return }
        // Warm-up: the first process call loads/compiles the model and is much slower.
        if let src = Self.blankSource(cfg: cfg, width: width, height: height) {
            for _ in 0..<2 {
                let sem = DispatchSemaphore(value: 0)
                if let params = makeParameters(previous: src, current: src, pool: pool) {
                    proc.process(parameters: params.0) { _, _ in sem.signal() }
                    _ = sem.wait(timeout: .now() + 5)
                }
            }
        }
        var warmProc: VTFrameProcessor?
        var warmPool: CVPixelBufferPool?
        if keepWarm {
            let w = VTFrameProcessor()
            if (try? w.startSession(configuration: cfg)) != nil {
                CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary,
                                        cfg.destinationPixelBufferAttributes as CFDictionary, &warmPool)
                if let warmPool, let src = Self.blankSource(cfg: cfg, width: width, height: height),
                   let params = makeParameters(previous: src, current: src, pool: warmPool) {
                    let sem = DispatchSemaphore(value: 0)
                    w.process(parameters: params.0) { _, _ in sem.signal() }
                    _ = sem.wait(timeout: .now() + 5)
                    warmProc = w
                } else {
                    w.endSession()
                }
            }
        }
        lock.lock()
        if gen == generation {
            processor?.endSession()
            processor = proc
            self.pool = pool
            warmProcessor?.endSession()
            warmProcessor = warmProc
            self.warmPool = warmPool
            configuredSize = (width, height)
            preparingSize = nil
            lock.unlock()
        } else {
            lock.unlock()
            proc.endSession()
            warmProc?.endSession()
        }
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

    private func makeParameters(previous: CVPixelBuffer, current: CVPixelBuffer, pool: CVPixelBufferPool)
        -> (VTLowLatencyFrameInterpolationParameters, CVPixelBuffer)? {
        var mid: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &mid)
        guard let mid else { return nil }
        ptsCounter += 2
        let t = ptsCounter
        guard let src = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: CMTime(value: t, timescale: 60)),
              let prev = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: CMTime(value: t - 2, timescale: 60)),
              let dst = VTFrameProcessorFrame(buffer: mid, presentationTimeStamp: CMTime(value: t - 1, timescale: 60)) else { return nil }
        guard let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: src, previousFrame: prev,
                                                                    interpolationPhase: [0.5], destinationFrames: [dst]) else { return nil }
        return (params, mid)
    }

    /// Asynchronous; `completion` runs on an arbitrary thread, exactly once.
    func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer, completion: @escaping (InterpolationResult) -> Void) {
        run(previous: previous, current: current, start: HostClock.now(), completion: completion)
    }

    /// Throw-away request on the last pair on the warm session, right after a real one finishes;
    /// skipped when it would still be running when the next real request is due.
    private func warm(previous: CVPixelBuffer, current: CVPixelBuffer) {
        let now = HostClock.seconds(HostClock.now())
        lock.lock()
        let nextDue = lastRequest + requestInterval
        guard requestInterval > 0, now + warmDuration + 0.002 < nextDue, !warmBusy, let proc = warmProcessor, let warmPool,
              let (params, _) = makeParameters(previous: previous, current: current, pool: warmPool) else { lock.unlock(); return }
        warmBusy = true
        lock.unlock()
        proc.process(parameters: params) { [weak self] _, _ in
            guard let self else { return }
            let took = HostClock.seconds(HostClock.now()) - now
            self.lock.withLock {
                self.warmBusy = false
                self.warmDuration += (min(took, 0.03) - self.warmDuration) * 0.2
            }
        }
    }

    private func run(previous: CVPixelBuffer, current: CVPixelBuffer, start: UInt64, completion: @escaping (InterpolationResult) -> Void) {
        lock.lock()
        guard !busy, let proc = processor, let pool, isReadyLocked(current), isReadyLocked(previous) else {
            let why = busy ? "busy" : "not ready"
            lock.unlock()
            completion(InterpolationResult(frames: [], wallMs: 0, error: why))
            return
        }
        guard let (params, mid) = makeParameters(previous: previous, current: current, pool: pool) else {
            lock.unlock()
            completion(InterpolationResult(frames: [], wallMs: 0, error: "parameters"))
            return
        }
        busy = true
        let t = HostClock.seconds(start)
        if lastRequest > 0 {
            let d = t - lastRequest
            if d > 0.005 && d < 0.1 { requestInterval = requestInterval == 0 ? d : requestInterval + (d - requestInterval) * 0.1 }
        }
        lastRequest = t
        lock.unlock()
        proc.process(parameters: params) { [weak self] _, error in
            self?.lock.withLock { self?.busy = false }
            let ms = HostClock.milliseconds(from: start, to: HostClock.now())
            if let error {
                completion(InterpolationResult(frames: [], wallMs: ms, error: "\(error)"))
            } else {
                completion(InterpolationResult(frames: [mid], wallMs: ms, error: nil))
                self?.warm(previous: previous, current: current)
            }
        }
    }

    private func isReadyLocked(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == PixelFormats.videoRange420, let s = configuredSize else { return false }
        return s.0 == CVPixelBufferGetWidth(buffer) && s.1 == CVPixelBufferGetHeight(buffer)
    }

    func reset() {
        lock.lock(); ptsCounter = 0; lock.unlock()
    }
}
