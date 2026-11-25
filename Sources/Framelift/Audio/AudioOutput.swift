// SPDX-License-Identifier: AGPL-3.0-only
// Low-latency playback of the PS5's PCM (interleaved S16, 48 kHz stereo, 10 ms chunks) through an
// SPSC ring and an AVAudioSourceNode on the default output device.
// Playback follows measured video delay, with gradual resampling for clock drift.
// AVAudioEngine binds to the default device when built, so device changes rebuild the engine.
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

final class AudioOutput: @unchecked Sendable {
    // MARK: Tunables

    static let maxMs: Double = 100
    /// Requested hardware IO buffer (frames at the device rate). Smaller = lower latency, more CPU wakeups.
    static let ioBufferFrames: UInt32 = 256

    // MARK: State

    private let ring = AudioRing(capacityFrames: 1 << 15) // ~680 ms @ 48 kHz, stereo float
    private let queue = DispatchQueue(label: "framelift.audio.engine", qos: .userInteractive)
    private let wantRunning = Atomic<Bool>(false)
    private let restartGeneration = Atomic<UInt64>(0)
    private let syncLock = NSLock()
    private var sync = AudioSync()
    private var offsetMs: Double = 0
    private var outputLatencyMs: Double = 0
    private var lastUnderruns = 0

    // Owned by `queue`.
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init() {
        ring.sampleRate.store(48000, ordering: .relaxed)
    }

    deinit {
        // Every queued closure holds a strong reference, so none can be pending here: tear down inline
        // (a queue.sync could deadlock if the last release happens on `queue`).
        teardownLocked(removeDeviceListener: true)
    }

    func start() {
        guard !wantRunning.exchange(true, ordering: .acquiringAndReleasing) else { return }
        queue.async {
            self.installDeviceListenerLocked()
            self.buildAndStartLocked()
        }
    }

    func stop() {
        guard wantRunning.exchange(false, ordering: .acquiringAndReleasing) else { return }
        queue.async { self.teardownLocked(removeDeviceListener: true) }
    }

    /// Any thread. Never blocks; drops the chunk if the ring is full (only possible while the engine is down).
    func enqueue(_ chunk: PCMChunk) {
        let channels = Int(chunk.channels)
        guard channels > 0, chunk.sampleRate > 0, !chunk.samples.isEmpty else { return }
        if chunk.discontinuity { resetSync() }
        ring.noteEnqueue()
        let current = ring.sampleRate.load(ordering: .relaxed)
        if chunk.sampleRate != current {
            // Stream format changed: rebuild the graph at the new rate; audio until then is discarded.
            if ring.pendingRate.exchange(chunk.sampleRate, ordering: .relaxed) != chunk.sampleRate {
                queue.async {
                    let rate = self.ring.pendingRate.load(ordering: .relaxed)
                    self.ring.sampleRate.store(rate, ordering: .relaxed)
                    if self.wantRunning.load(ordering: .relaxed) { self.buildAndStartLocked() }
                }
            }
            return
        }
        chunk.samples.withUnsafeBufferPointer { ring.write(interleavedS16: $0, channels: channels) }
    }

    func setOffset(milliseconds: Double) {
        syncLock.withLock { offsetMs = milliseconds }
    }

    var presentationDelayMs: Double {
        syncLock.withLock { sync.targetMs + outputLatencyMs }
    }

    func noteVideoPresentation(arrival: Double, presented: Double) {
        guard arrival > 0, presented > arrival else { return }
        syncLock.withLock {
            let underruns = ring.underruns.load(ordering: .relaxed)
            if underruns > lastUnderruns {
                sync.noteUnderrun(deliveryOutage: ring.deliveryIsRecovering())
                lastUnderruns = underruns
            }
            sync.observe(videoDelayMs: (presented - arrival) * 1000,
                         outputLatencyMs: outputLatencyMs, offsetMs: offsetMs)
            if sync.settled {
                ring.targetFrames.store(Int(Double(ring.sampleRate.load(ordering: .relaxed)) * sync.targetMs / 1000), ordering: .relaxed)
                ring.syncReady.store(true, ordering: .releasing)
            }
        }
    }

    func resetSync() {
        syncLock.withLock {
            sync = AudioSync()
            lastUnderruns = ring.underruns.load(ordering: .relaxed)
            ring.resetDeliveryClock()
        }
        ring.targetFrames.store(1920, ordering: .relaxed)
        ring.flushRequested.store(true, ordering: .releasing)
        ring.syncReady.store(false, ordering: .relaxed)
        ring.firstAudioTime.store(0, ordering: .relaxed)
    }

    var diagnostics: String {
        let state = syncLock.withLock { (sync.targetMs, sync.minimumTargetMs) }
        return String(format: "audio playback target=%.1fms underruns=%d overflows=%d enqueue-gap-max=%.1fms callback-gap-max=%.1fms callback-frames-max=%d minimum=%.1fms delivery-recovery=%d", state.0,
                      ring.underruns.load(ordering: .relaxed), ring.overflows.load(ordering: .relaxed),
                      HostClock.seconds(ring.enqueueGapMax.load(ordering: .relaxed)) * 1000,
                      HostClock.seconds(ring.callbackGapMax.load(ordering: .relaxed)) * 1000, ring.callbackFramesMax.load(ordering: .relaxed),
                      state.1, ring.deliveryIsRecovering() ? 1 : 0)
    }

    // MARK: Engine lifecycle (on `queue`)

    private func buildAndStartLocked() {
        teardownLocked(removeDeviceListener: false)
        guard wantRunning.load(ordering: .relaxed) else { return }

        let rate = Double(ring.sampleRate.load(ordering: .relaxed))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let engine = AVAudioEngine()
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            ring.noteCallback(frames: Int(frameCount))
            let target = ring.targetFrames.load(ordering: .relaxed)
            let first = ring.firstAudioTime.load(ordering: .relaxed)
            let waiting = !ring.syncReady.load(ordering: .acquiring)
                && (first == 0 || HostClock.seconds(HostClock.now() - first) < 2)
            ring.render(into: UnsafeMutableAudioBufferListPointer(abl),
                        frames: Int(frameCount),
                        isSilence: isSilence,
                        prefill: target, target: target, maxFrames: max(Int(rate * Self.maxMs / 1000), target + Int(rate * 0.08)),
                        waitingForVideo: waiting)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        Self.requestIOBuffer(engine.outputNode, frames: Self.ioBufferFrames)
        syncLock.withLock { outputLatencyMs = engine.outputNode.presentationLatency * 1000 }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "configuration change")
        }

        ring.flushForStart() // consumer is not running: safe to move the read index
        engine.prepare()
        // Kept even if start fails, so the next teardown stops and detaches it.
        self.engine = engine
        self.sourceNode = node
        do {
            try engine.start()
            syncLock.withLock { outputLatencyMs = engine.outputNode.presentationLatency * 1000 }
        } catch {
            NSLog("[AudioOutput] engine start failed: \(error); retrying in 500 ms")
            scheduleRestart(reason: "start failure", delay: 0.5)
            return
        }
    }

    private func teardownLocked(removeDeviceListener: Bool) {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let engine {
            engine.stop()
            if let sourceNode { engine.detach(sourceNode) }
        }
        engine = nil
        sourceNode = nil
        if removeDeviceListener, let block = deviceListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            deviceListener = nil
        }
    }

    /// Coalesces bursts of device / configuration notifications into one rebuild.
    private func scheduleRestart(reason: String, delay: Double = 0.1) {
        let generation = restartGeneration.add(1, ordering: .relaxed).newValue
        queue.asyncAfter(deadline: .now() + delay) {
            guard self.restartGeneration.load(ordering: .relaxed) == generation,
                  self.wantRunning.load(ordering: .relaxed) else { return }
            NSLog("[AudioOutput] restarting engine (\(reason))")
            self.buildAndStartLocked()
        }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installDeviceListenerLocked() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(reason: "default output device changed")
        }
        var address = Self.defaultOutputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr { deviceListener = block }
    }

    private static func requestIOBuffer(_ output: AVAudioOutputNode, frames: UInt32) {
        guard let unit = output.audioUnit else { return }
        var size = frames
        // Best effort: the HAL clamps to the device's allowed range.
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &size, UInt32(MemoryLayout<UInt32>.size))
    }
}

// MARK: - Single-producer / single-consumer ring

/// Interleaved stereo Float32 ring. Producer = `enqueue` caller, consumer = the render thread.
/// Indices are monotonically increasing frame counters; only the consumer moves `readIndex`
/// (including drops), only the producer moves `writeIndex`. No locks, no allocation on either side.
final class AudioRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>

    let writeIndex = Atomic<UInt64>(0)
    let readIndex = Atomic<UInt64>(0)
    let sampleRate = Atomic<UInt32>(48000)
    let pendingRate = Atomic<UInt32>(48000)
    private let lastEnqueue = Atomic<UInt64>(0)
    private let lastDeliveryOutage = Atomic<UInt64>(0)
    private static let outageTicks = HostClock.ticks(seconds: AudioSync.maximumJitterMs / 1000)
    private static let recoveryTicks = HostClock.ticks(seconds: 1)
    private let lastCallback = Atomic<UInt64>(0)
    let enqueueGapMax = Atomic<UInt64>(0)
    let callbackGapMax = Atomic<UInt64>(0)
    let callbackFramesMax = Atomic<Int>(0)

    func noteEnqueue(at now: UInt64 = HostClock.now()) {
        let previous = lastEnqueue.load(ordering: .relaxed)
        if previous > 0, now >= previous {
            let gap = now - previous
            if gap > enqueueGapMax.load(ordering: .relaxed) { enqueueGapMax.store(gap, ordering: .relaxed) }
            if gap > Self.outageTicks { lastDeliveryOutage.store(now, ordering: .relaxed) }
        }
        lastEnqueue.store(now, ordering: .releasing)
    }

    func deliveryIsRecovering(at now: UInt64 = HostClock.now()) -> Bool {
        let last = lastEnqueue.load(ordering: .acquiring)
        if last > 0, now >= last, now - last > Self.outageTicks { return true }
        let outage = lastDeliveryOutage.load(ordering: .relaxed)
        return outage > 0 && now >= outage && now - outage < Self.recoveryTicks
    }

    func resetDeliveryClock() {
        lastDeliveryOutage.store(0, ordering: .relaxed)
        lastEnqueue.store(0, ordering: .releasing)
    }

    func noteCallback(frames: Int) {
        Self.noteGap(last: lastCallback, maximum: callbackGapMax)
        if frames > callbackFramesMax.load(ordering: .relaxed) { callbackFramesMax.store(frames, ordering: .relaxed) }
    }

    private static func noteGap(last: borrowing Atomic<UInt64>, maximum: borrowing Atomic<UInt64>) {
        let now = HostClock.now()
        let previous = last.exchange(now, ordering: .relaxed)
        if previous > 0, now >= previous {
            let gap = now - previous
            if gap > maximum.load(ordering: .relaxed) { maximum.store(gap, ordering: .relaxed) }
        }
    }

    let underruns = Atomic<Int>(0)
    let overflows = Atomic<Int>(0)
    let flushRequested = Atomic<Bool>(false)
    let targetFrames = Atomic<Int>(1920)
    let syncReady = Atomic<Bool>(false)
    let firstAudioTime = Atomic<UInt64>(0)

    // Consumer-only state (render thread, or the engine queue while the render thread is stopped).
    private var priming = true
    private var fraction: Double = 0
    private var previousLeft: Float = 0
    private var previousRight: Float = 0
    private var fadeRemaining = 0

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0)
        capacity = capacityFrames
        mask = capacityFrames - 1
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    /// Producer side.
    func write(interleavedS16 src: UnsafeBufferPointer<Int16>, channels: Int) {
        let frames = src.count / channels
        guard frames > 0 else { return }
        if firstAudioTime.load(ordering: .relaxed) == 0 { firstAudioTime.store(HostClock.now(), ordering: .relaxed) }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - Int(w - r)
        guard frames <= free else { return }
        let scale: Float = 1.0 / 32768.0
        var pos = Int(w & UInt64(mask))
        for f in 0..<frames {
            let base = f * channels
            let l = Float(src[base]) * scale
            let rr = channels >= 2 ? Float(src[base + 1]) * scale : l
            storage[pos * 2] = l
            storage[pos * 2 + 1] = rr
            pos = (pos + 1) & mask
        }
        writeIndex.store(w + UInt64(frames), ordering: .releasing)
    }

    /// Called while no render callback can run (engine stopped). Drops everything buffered.
    func flushForStart() {
        let w = writeIndex.load(ordering: .acquiring)
        readIndex.store(w, ordering: .releasing)
        priming = true
        fraction = 0
        previousLeft = 0
        previousRight = 0
        fadeRemaining = 64
    }

    /// Consumer side (real-time thread).
    func render(into abl: UnsafeMutableAudioBufferListPointer, frames: Int,
                isSilence: UnsafeMutablePointer<ObjCBool>,
                prefill: Int, target: Int, maxFrames: Int,
                waitingForVideo: Bool = false) {
        guard abl.count >= 1, let left = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = abl.count >= 2 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
        if flushRequested.exchange(false, ordering: .acquiringAndReleasing) { flushForStart() }
        isSilence.pointee = false
        if waitingForVideo {
            fillSilence(left, right, from: 0, to: frames)
            isSilence.pointee = true
            return
        }

        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        var available = Int(w &- r)

        if priming {
            if available >= prefill {
                priming = false
                fadeRemaining = 64
                if available > target { // start right at the target latency
                    let drop = available - target
                    r &+= UInt64(drop)
                    available = target
                }
            } else {
                fillSilence(left, right, from: 0, to: frames)
                isSilence.pointee = true
                return
            }
        }

        if available > maxFrames {
            overflows.add(1, ordering: .relaxed)
            let drop = available - target
            r &+= UInt64(drop)
            available = target
            fraction = 0
            fadeRemaining = 64
        }

        let step = AudioSync.driftStep(available: available, target: target, rate: Double(sampleRate.load(ordering: .relaxed)))
        var consumed = 0
        var n = 0
        while n < frames, consumed + 1 < available {
            let at = Int((r + UInt64(consumed)) & UInt64(mask))
            let next = (at + 1) & mask
            let weight = Float(fraction)
            var l = storage[at * 2] * (1 - weight) + storage[next * 2] * weight
            var rr = storage[at * 2 + 1] * (1 - weight) + storage[next * 2 + 1] * weight
            if fadeRemaining > 0 {
                let gain = 1 / Float(fadeRemaining)
                l = previousLeft + (l - previousLeft) * gain
                rr = previousRight + (rr - previousRight) * gain
                fadeRemaining -= 1
            }
            left[n] = l
            right?[n] = rr
            previousLeft = l; previousRight = rr
            fraction += step
            let advance = Int(fraction)
            fraction -= Double(advance)
            consumed += advance
            n += 1
        }
        if n < frames {
            underruns.add(1, ordering: .relaxed)
            for i in n..<frames {
                let gain = max(0, 1 - Float(i - n + 1) / 64)
                left[i] = previousLeft * gain
                right?[i] = previousRight * gain
            }
            previousLeft = 0
            previousRight = 0
            priming = true
            fraction = 0
        }
        readIndex.store(r &+ UInt64(min(consumed, available)), ordering: .releasing)
    }

    @inline(__always)
    private func fillSilence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, from: Int, to: Int) {
        guard to > from else { return }
        (left + from).update(repeating: 0, count: to - from)
        (right.map { $0 + from })?.update(repeating: 0, count: to - from)
    }
}
