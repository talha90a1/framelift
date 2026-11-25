// SPDX-License-Identifier: AGPL-3.0-only
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class HDRFrameInterpolator: FrameInterpolator, @unchecked Sendable {
    var backendName: String { "Apple ML HDR interpolation" }
    static var isSupported: Bool { VTOpticalFlowConfiguration.isSupported && VTFrameRateConversionConfiguration.isSupported }

    private struct Request {
        let id = UUID()
        let previous: CVPixelBuffer
        let current: CVPixelBuffer
        let start: UInt64
        let completion: (InterpolationResult) -> Void
    }

    private final class Session {
        let processor: VTFrameProcessor
        let flowProcessor: VTFrameProcessor
        let flowPool: CVPixelBufferPool
        let modelFlowPool: CVPixelBufferPool
        let motionWidth: Int
        let motionHeight: Int
        let width: Int
        let height: Int
        let queue: DispatchQueue
        var busy = false
        var counter: Int64 = 0
        var cachedSource: CVPixelBuffer?
        var cachedMotion: CVPixelBuffer?
        var cachedFlowMotion: CVPixelBuffer?

        init(
            processor: VTFrameProcessor, flowProcessor: VTFrameProcessor, flowPool: CVPixelBufferPool, modelFlowPool: CVPixelBufferPool,
            width: Int, height: Int, motionWidth: Int, motionHeight: Int, queue: DispatchQueue
        ) {
            self.processor = processor
            self.flowProcessor = flowProcessor
            self.flowPool = flowPool
            self.modelFlowPool = modelFlowPool
            self.motionWidth = motionWidth
            self.motionHeight = motionHeight
            self.width = width
            self.height = height
            self.queue = queue
        }

        deinit {
            queue.async { [processor, flowProcessor] in
                processor.endSession(); flowProcessor.endSession()
            }
        }

        func makeFlow(model: Bool = false) -> VTFrameProcessorOpticalFlow? {
            var forward: CVPixelBuffer?, backward: CVPixelBuffer?
            let pool = model ? modelFlowPool : flowPool
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &forward)
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &backward)
            guard let forward, let backward else { return nil }
            return VTFrameProcessorOpticalFlow(forwardFlow: forward, backwardFlow: backward)
        }

    }

    private let context: RenderContext
    private let converter: HDRColorConverter
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "framelift.hdr-interp.setup", qos: .userInitiated)
    private var session: Session?
    private var preparing: (Int, Int)?
    private var generation = 0
    private var pending: Request?
    private let maximumWait = 0.008
    private var primed = false

    init(context: RenderContext) throws {
        self.context = context
        converter = try HDRColorConverter(context: context)
    }

    var isPrimed: Bool { lock.withLock { primed } }

    func prime(previous: CVPixelBuffer, current: CVPixelBuffer) {
        let available = lock.withLock { !primed && session?.busy == false && pending == nil }
        if available { interpolate(previous: previous, current: current) { _ in } }
    }

    func isReady(for buffer: CVPixelBuffer) -> Bool {
        lock.withLock { session.map { matches(buffer, session: $0) } ?? false }
    }

    func prepare(width: Int, height: Int) {
        lock.lock()
        if let session, session.width == width, session.height == height { lock.unlock(); return }
        if let preparing, preparing == (width, height) { lock.unlock(); return }
        preparing = (width, height)
        generation += 1
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            var ready: Session?
            let motionWidth = min(width, 640)
            let motionHeight = max(2, height * motionWidth / width / 2 * 2)
            if Self.isSupported,
                let config = VTOpticalFlowConfiguration(
                    frameWidth: motionWidth, frameHeight: motionHeight,
                    qualityPrioritization: .normal, revision: VTOpticalFlowConfiguration.defaultRevision),
                let fullFlowConfig = VTOpticalFlowConfiguration(
                    frameWidth: width, frameHeight: height,
                    qualityPrioritization: .normal, revision: VTOpticalFlowConfiguration.defaultRevision),
                let renderConfig = VTFrameRateConversionConfiguration(
                    frameWidth: width, frameHeight: height,
                    usePrecomputedFlow: true, qualityPrioritization: .normal,
                    revision: VTFrameRateConversionConfiguration.defaultRevision)
            {
                let processor = VTFrameProcessor(), flowProcessor = VTFrameProcessor()
                do {
                    try flowProcessor.startSession(configuration: config)
                    try processor.startSession(configuration: renderConfig)
                    var pool: CVPixelBufferPool?
                    var modelPool: CVPixelBufferPool?
                    CVPixelBufferPoolCreate(
                        nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                        fullFlowConfig.destinationPixelBufferAttributes as CFDictionary, &pool)
                    CVPixelBufferPoolCreate(
                        nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                        config.destinationPixelBufferAttributes as CFDictionary, &modelPool)
                    if let pool, let modelPool {
                        let session = Session(
                            processor: processor, flowProcessor: flowProcessor, flowPool: pool, modelFlowPool: modelPool,
                            width: width, height: height, motionWidth: motionWidth, motionHeight: motionHeight, queue: self.queue)
                        ready = session
                    } else {
                        processor.endSession()
                        flowProcessor.endSession()
                    }
                } catch {
                    processor.endSession()
                    flowProcessor.endSession()
                    NSLog("[render] HDR interpolation setup failed: %@", "\(error)")
                }
            }
            self.lock.withLock {
                guard gen == self.generation else { return }
                self.session = ready
                self.primed = false
                self.preparing = nil
            }
        }
    }

    func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer, completion: @escaping (InterpolationResult) -> Void) {
        run(Request(previous: previous, current: current, start: HostClock.now(), completion: completion))
    }

    private func reject(_ request: Request, reason: String) {
        request.completion(
            InterpolationResult(
                frames: [],
                wallMs: HostClock.milliseconds(from: request.start, to: HostClock.now()), error: reason))
    }

    private func expire(_ id: UUID) {
        let request = lock.withLock { () -> Request? in
            guard pending?.id == id else { return nil }
            defer { pending = nil }
            return pending
        }
        if let request { reject(request, reason: "busy") }
    }

    private func run(_ request: Request) {
        let previous = request.previous, current = request.current, start = request.start, completion = request.completion
        lock.lock()
        guard let session, matches(previous, session: session), matches(current, session: session),
            ColourTags.read(previous) == ColourTags.read(current)
        else {
            lock.unlock()
            reject(request, reason: "not ready")
            return
        }
        if session.busy {
            let replaced = pending
            pending = request
            lock.unlock()
            if let replaced { reject(replaced, reason: "superseded") }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + maximumWait) { [weak self] in
                self?.expire(request.id)
            }
            return
        }
        session.busy = true
        let gen = generation
        let cached = session.cachedSource === previous ? session.cachedMotion : nil
        let cachedFlow = cached == nil ? nil : session.cachedFlowMotion
        session.counter += 2
        let time = session.counter
        lock.unlock()

        let finish: (CVPixelBuffer?, String?) -> Void = { [self, session] buffer, error in
            var next: Request?
            let valid = lock.withLock { () -> Bool in
                session.busy = false
                next = pending
                pending = nil
                if error != nil {
                    session.cachedSource = nil
                    session.cachedMotion = nil
                    session.cachedFlowMotion = nil
                }
                let valid = generation == gen && self.session === session
                if valid, buffer != nil { primed = true }
                return valid
            }
            completion(
                InterpolationResult(
                    frames: valid ? buffer.map { [$0] } ?? [] : [],
                    wallMs: HostClock.milliseconds(from: start, to: HostClock.now()), error: valid ? error : "reset"))
            if let next {
                if !valid {
                    reject(next, reason: "reset")
                } else if HostClock.seconds(HostClock.now() - next.start) > maximumWait {
                    reject(next, reason: "busy")
                } else {
                    run(next)
                }
            }
        }
        let convertedPrevious: (CVPixelBuffer?) -> Void = { [self, session] before in
            guard let before else { finish(nil, "HDR source conversion"); return }
            converter.motion(current) { [self, session] after in
                guard let after, let cb = context.queue.makeCommandBuffer(), let flow = session.makeFlow(),
                    let modelFlow = session.makeFlow(model: true),
                    let motionA = cachedFlow ?? converter.scaledMotion(before, width: session.motionWidth, height: session.motionHeight, command: cb),
                    let motionB = converter.scaledMotion(after, width: session.motionWidth, height: session.motionHeight, command: cb),
                    let flowA = VTFrameProcessorFrame(buffer: motionA, presentationTimeStamp: CMTime(value: time - 2, timescale: 60)),
                    let flowB = VTFrameProcessorFrame(buffer: motionB, presentationTimeStamp: CMTime(value: time, timescale: 60)),
                    let mid = converter.makeRGB(width: session.width, height: session.height),
                    let a = VTFrameProcessorFrame(buffer: before, presentationTimeStamp: CMTime(value: time - 2, timescale: 60)),
                    let b = VTFrameProcessorFrame(buffer: after, presentationTimeStamp: CMTime(value: time, timescale: 60)),
                    let dst = VTFrameProcessorFrame(buffer: mid, presentationTimeStamp: CMTime(value: time - 1, timescale: 60)),
                    let render = VTFrameRateConversionParameters(
                        sourceFrame: a, nextFrame: b, opticalFlow: flow,
                        interpolationPhase: [0.5], submissionMode: cached == nil ? .random : .sequential, destinationFrames: [dst]),
                    let params = VTOpticalFlowParameters(
                        sourceFrame: flowA, nextFrame: flowB,
                        submissionMode: cached == nil ? .random : .sequential, destinationOpticalFlow: modelFlow)
                else { finish(nil, "HDR motion parameters"); return }
                lock.withLock {
                    if generation == gen {
                        session.cachedSource = current
                        session.cachedMotion = after
                        session.cachedFlowMotion = motionB
                    }
                }
                session.flowProcessor.process(with: cb, parameters: params)
                guard converter.rescaleFlow(modelFlow.forwardFlow, into: flow.forwardFlow, command: cb),
                    converter.rescaleFlow(modelFlow.backwardFlow, into: flow.backwardFlow, command: cb)
                else { finish(nil, "HDR flow conversion"); return }
                session.processor.process(with: cb, parameters: render)
                cb.addCompletedHandler { [self, session] command in
                    withExtendedLifetime((session, before, after, motionA, motionB, modelFlow, flow, mid)) {}
                    if let error = command.error { finish(nil, "\(error)"); return }
                    converter.encoded(mid, matching: current) {
                        finish($0, $0 == nil ? "HDR output conversion" : nil)
                    }
                }
                cb.commit()
            }
        }
        if let cached { convertedPrevious(cached) } else { converter.motion(previous, completion: convertedPrevious) }
    }

    private func matches(_ buffer: CVPixelBuffer, session: Session) -> Bool {
        PixelFormats.is10Bit420(buffer) && ColourTags.read(buffer).hdrCurve != nil
            && CVPixelBufferGetWidth(buffer) == session.width && CVPixelBufferGetHeight(buffer) == session.height
    }

    func reset() {
        let request = lock.withLock { () -> Request? in
            generation += 1
            preparing = nil
            primed = false
            session?.cachedSource = nil
            session?.cachedMotion = nil
            session?.cachedFlowMotion = nil
            defer { pending = nil }
            return pending
        }
        if let request { reject(request, reason: "reset") }
    }
}
