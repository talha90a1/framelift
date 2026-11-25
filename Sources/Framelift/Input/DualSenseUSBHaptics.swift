// SPDX-License-Identifier: AGPL-3.0-only
// DualSense haptics over USB: channels 3/4 of the pad's 4-channel audio device drive the actuators.
// The console's 3 kHz S16 is upsampled and played via an AUHAL unit bound to that device. Not verified on hardware.
import AudioToolbox
import CoreAudio
import Foundation
import os

protocol USBHapticsDevice: AnyObject, Sendable {
    func enqueue(_ samples: [Int16])
    func stop()
}

final class USBHapticsRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "framelift.dualsense.usb.open", qos: .utility)
    private let open: @Sendable () -> (any USBHapticsDevice)?
    private let clock: @Sendable () -> Double
    private var nextAttempt = -Double.infinity
    private var opening = false
    private var finished = false
    private var stopped = false
    private var pending: (any USBHapticsDevice)?

    init(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         open: @escaping @Sendable () -> (any USBHapticsDevice)?) {
        self.clock = clock
        self.open = open
    }

    func poll() -> (any USBHapticsDevice)? {
        lock.lock()
        if let pending {
            self.pending = nil
            finished = true
            lock.unlock()
            return pending
        }
        guard !stopped, !finished, !opening, clock() >= nextAttempt else { lock.unlock(); return nil }
        opening = true
        nextAttempt = clock() + 1
        lock.unlock()
        queue.async { [self] in
            let device = open()
            lock.lock()
            opening = false
            let discard = stopped
            if !discard { pending = device }
            lock.unlock()
            if discard { device?.stop() }
        }
        return nil
    }

    func stop() {
        lock.lock()
        stopped = true
        let device = pending
        pending = nil
        lock.unlock()
        device?.stop()
    }
}

final class DualSenseUSBHaptics: USBHapticsDevice, @unchecked Sendable {
    /// ~100 ms of 3 kHz frames; older frames are dropped so latency stays bounded.
    static let ringFrames = 300

    private struct Ring {
        var left = [Float](repeating: 0, count: DualSenseUSBHaptics.ringFrames)
        var right = [Float](repeating: 0, count: DualSenseUSBHaptics.ringFrames)
        var read = 0, count = 0
        var a: (Float, Float) = (0, 0), b: (Float, Float) = (0, 0), frac: Double = 0

        mutating func push(_ l: Float, _ r: Float) {
            if count == DualSenseUSBHaptics.ringFrames { read = (read + 1) % left.count; count -= 1 }
            let w = (read + count) % left.count
            left[w] = l; right[w] = r; count += 1
        }

        mutating func pop() -> (Float, Float) {
            guard count > 0 else { return (0, 0) }
            let v = (left[read], right[read])
            read = (read + 1) % left.count; count -= 1
            return v
        }
    }

    private var unit: AudioUnit?
    private let ring = OSAllocatedUnfairLock(initialState: Ring())
    private let step: Double

    /// Nil when no DualSense audio device with 4+ output channels exists or the unit won't start.
    init?(log: (String) -> Void) {
        guard let (deviceID, channels, rate) = Self.findDevice() else {
            log("dualsense usb audio device not found; haptics as report rumble")
            return nil
        }
        step = 3000.0 / rate
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return nil }
        unit = instance

        var device = deviceID
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: Self.render, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let steps: [(String, OSStatus)] = [
            ("device", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                            &device, UInt32(MemoryLayout<AudioDeviceID>.size))),
            ("format", AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))),
            ("callback", AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                              &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))),
            ("init", AudioUnitInitialize(instance)),
            ("start", AudioOutputUnitStart(instance)),
        ]
        if let failed = steps.first(where: { $0.1 != noErr }) {
            log("dualsense usb audio \(failed.0) failed: \(failed.1); haptics as report rumble")
            AudioComponentInstanceDispose(instance)
            unit = nil
            return nil
        }
        log("dualsense usb audio haptics: device \(deviceID), \(channels) ch @ \(Int(rate)) Hz")
    }

    deinit { stop() }

    func enqueue(_ samples: [Int16]) {
        ring.withLock { r in
            var i = 0
            while i + 1 < samples.count {
                r.push(Float(samples[i]) / 32768, Float(samples[i + 1]) / 32768)
                i += 2
            }
        }
    }

    func stop() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private static let render: AURenderCallback = { refCon, _, _, _, frames, ioData in
        guard let ioData else { return noErr }
        let me = Unmanaged<DualSenseUSBHaptics>.fromOpaque(refCon).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for b in buffers { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
        guard buffers.count >= 4,
              let l = buffers[2].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[3].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let step = me.step
        me.ring.withLockUnchecked { ring in
            for i in 0..<Int(frames) {
                let f = Float(ring.frac)
                l[i] = ring.a.0 + (ring.b.0 - ring.a.0) * f
                r[i] = ring.a.1 + (ring.b.1 - ring.a.1) * f
                ring.frac += step
                while ring.frac >= 1 {
                    ring.frac -= 1
                    ring.a = ring.b
                    ring.b = ring.pop()
                }
            }
        }
        return noErr
    }

    // MARK: Device lookup

    /// The USB audio device named "DualSense…" with at least 4 output channels.
    static func findDevice() -> (AudioDeviceID, channels: Int, rate: Double)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            guard let name = stringProperty(id, kAudioObjectPropertyName), name.localizedCaseInsensitiveContains("DualSense"),
                  uint32Property(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeUSB
            else { continue }
            let channels = outputChannels(id)
            guard channels >= 4 else { continue }
            var rate: Float64 = 48000
            var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            _ = AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &rateSize, &rate)
            return (id, channels, rate > 0 ? rate : 48000)
        }
        return nil
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func outputChannels(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
