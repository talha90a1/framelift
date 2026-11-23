// SPDX-License-Identifier: AGPL-3.0-only
// Low-latency playback of the PS5's PCM (interleaved S16, 48 kHz stereo, 10 ms chunks) through an
// SPSC ring and an AVAudioSourceNode on the default output device.
// Latency policy (render thread): prefill `prefillMs` after start/underrun, drop down to `targetMs`
// above `maxMs`, and trim drift when the buffer stayed above `targetMs + trimSlackMs` for 1 s.
// AVAudioEngine binds to the default device when built, so device changes rebuild the engine.
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

final class AudioOutput: @unchecked Sendable {
    // MARK: Tunables

    static let targetMs: Double = 40
    static let prefillMs: Double = 30
    static let maxMs: Double = 100
    static let trimSlackMs: Double = 20
    /// Requested hardware IO buffer (frames at the device rate). Smaller = lower latency, more CPU wakeups.
    static let ioBufferFrames: UInt32 = 256

    // MARK: State

    private let ring = AudioRing(capacityFrames: 1 << 15) // ~680 ms @ 48 kHz, stereo float
    private let queue = DispatchQueue(label: "framelift.audio.engine", qos: .userInteractive)
    private let wantRunning = Atomic<Bool>(false)
    private let restartGeneration = Atomic<UInt64>(0)

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

    // MARK: Engine lifecycle (on `queue`)

    private func buildAndStartLocked() {
        teardownLocked(removeDeviceListener: false)
        guard wantRunning.load(ordering: .relaxed) else { return }

        let rate = Double(ring.sampleRate.load(ordering: .relaxed))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let engine = AVAudioEngine()
        let ring = self.ring
        let prefill = Int(rate * Self.prefillMs / 1000)
        let target = Int(rate * Self.targetMs / 1000)
        let maxFrames = Int(rate * Self.maxMs / 1000)
        let trimSlack = Int(rate * Self.trimSlackMs / 1000)
        let window = Int(rate) // 1 s drift observation window
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            ring.render(into: UnsafeMutableAudioBufferListPointer(abl),
                        frames: Int(frameCount),
                        isSilence: isSilence,
                        prefill: prefill, target: target, maxFrames: maxFrames,
                        trimSlack: trimSlack, window: window)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        Self.requestIOBuffer(engine.outputNode, frames: Self.ioBufferFrames)

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

    // Consumer-only state (render thread, or the engine queue while the render thread is stopped).
    private var priming = true
    private var windowMin = Int.max
    private var windowFrames = 0

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
        windowMin = .max
        windowFrames = 0
    }

    /// Consumer side (real-time thread).
    func render(into abl: UnsafeMutableAudioBufferListPointer, frames: Int,
                isSilence: UnsafeMutablePointer<ObjCBool>,
                prefill: Int, target: Int, maxFrames: Int, trimSlack: Int, window: Int) {
        guard abl.count >= 1, let left = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = abl.count >= 2 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        var available = Int(w &- r)

        if priming {
            if available >= prefill {
                priming = false
                if available > target { // start right at the target latency
                    let drop = available - target
                    r &+= UInt64(drop)
                    available = target
                }
                windowMin = .max
                windowFrames = 0
            } else {
                fillSilence(left, right, from: 0, to: frames)
                isSilence.pointee = true
                return
            }
        }

        if available > maxFrames {
            let drop = available - target
            r &+= UInt64(drop)
            available = target
            windowMin = .max
            windowFrames = 0
        } else {
            windowMin = min(windowMin, available)
            windowFrames += frames
            if windowFrames >= window {
                if windowMin != .max, windowMin > target + trimSlack {
                    let drop = windowMin - target
                    r &+= UInt64(drop)
                    available -= drop
                }
                windowMin = .max
                windowFrames = 0
            }
        }

        let n = min(available, frames)
        var pos = Int(r & UInt64(mask))
        for i in 0..<n {
            left[i] = storage[pos * 2]
            right?[i] = storage[pos * 2 + 1]
            pos = (pos + 1) & mask
        }
        if n < frames {
            fillSilence(left, right, from: n, to: frames)
            priming = true
        }
        readIndex.store(r &+ UInt64(n), ordering: .releasing)
    }

    @inline(__always)
    private func fillSilence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, from: Int, to: Int) {
        guard to > from else { return }
        (left + from).update(repeating: 0, count: to - from)
        (right.map { $0 + from })?.update(repeating: 0, count: to - from)
    }
}
