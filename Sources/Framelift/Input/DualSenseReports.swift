// SPDX-License-Identifier: AGPL-3.0-only
// DualSense HID output reports, built byte for byte (pure, no IOKit; unit tested).
// Ported from P5M (github.com/beecrepaldi-afk/P5M, AGPL-3.0, commit d61c8e6), offsets as in Linux
// hid-playstation.c. USB 0x02 framing follows cestercian/ps5-mac-companion (MIT, Copyright (c) 2026
// Cestercian), with the report ID as the first byte (hidapi/IOKit convention).
//
// The 47-byte "common" block (kernel struct) sits at offset 1 in USB report 0x02 (48 bytes) and at
// offset 3 in Bluetooth report 0x31 (78 bytes: 0x31, seq<<4, 0x10 tag, block, padding, CRC32).
//   0 valid0     0x01 compatible vibration, 0x02 haptics select, 0x04 right trigger, 0x08 left trigger
//   1 valid1     0x02 power save/mute, 0x20 haptics low-pass, 0x40 motor power reduction
//   2 motor right   3 motor left   9 power save / mute
//   10..20 right trigger (type + 10 params)   21..31 left trigger
//   36 motor power reduction   38 valid2 (0x04 compatible vibration v2)   39 haptics low-pass (P5M)
// Bluetooth CRC32 (zlib) covers the byte 0xA2 followed by everything before the last 4 bytes, and
// is stored little endian in those 4 bytes.
//
// Report 0x32 (Bluetooth haptics, 142 bytes): 0x32, seq<<4, 0x91 0x07 0xFE, 5 × queue depth (16),
// audio counter, 0x92 0x40, 64 bytes = 32 stereo frames of signed 8-bit PCM at 3 kHz, zeros, CRC32.
import Foundation

enum DualSenseTransport: String, Sendable {
    case usb = "USB"
    case bluetooth = "Bluetooth"
}

enum DualSenseReports {
    static let btStateID: UInt8 = 0x31
    static let btStateSize = 78
    static let btHapticsID: UInt8 = 0x32
    static let btHapticsSize = 142
    static let usbStateID: UInt8 = 0x02
    static let commonSize = 47

    static let hapticsFrames = 32                 // stereo frames per 0x32
    static let hapticsBytes = hapticsFrames * 2   // 64
    static let hapticsOffset = 13
    /// In-controller audio queue depth in frames (P5M: DS5Dongle's minimum, 16).
    static let hapticsQueueDepth: UInt8 = 16
    /// S16 amplitude that maps to full scale 127 in the 8-bit stream (linear, clamped): twice the
    /// console's own level, as in P5M.
    static let hapticsFullScale: Int32 = 16384

    enum Common {
        static let valid0 = 0, valid1 = 1, motorRight = 2, motorLeft = 3, powerSave = 9
        static let rightTrigger = 10, leftTrigger = 21, motorPower = 36, valid2 = 38, lowPass = 39
    }

    enum Valid0 {
        static let hapticsSelect: UInt8 = 0x02, rightTrigger: UInt8 = 0x04, leftTrigger: UInt8 = 0x08
    }

    enum Valid1 {
        static let powerSave: UInt8 = 0x02, lowPass: UInt8 = 0x20, motorPower: UInt8 = 0x40
    }

    static let valid2CompatibleVibration: UInt8 = 0x04

    /// The neutral trigger effect: type 0x05 (off) with zero params.
    static let triggerOff: (type: UInt8, params: [UInt8]) = (0x05, [UInt8](repeating: 0, count: 10))

    // MARK: Common block contents

    static func triggerBlock(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: commonSize)
        c[Common.valid0] = Valid0.rightTrigger | Valid0.leftTrigger
        put(type: typeRight, params: right, into: &c, at: Common.rightTrigger)
        put(type: typeLeft, params: left, into: &c, at: Common.leftTrigger)
        return c
    }

    /// Full actuator power, haptics low-pass on, no power save or mute. Sent once before haptics
    /// (P5M `potenciaCheia`). valid0 stays 0: the rumble emulation bits take the actuators out of
    /// audio mode.
    static func powerSetupBlock() -> [UInt8] {
        var c = [UInt8](repeating: 0, count: commonSize)
        c[Common.valid1] = Valid1.powerSave | Valid1.lowPass | Valid1.motorPower
        c[Common.powerSave] = 0
        c[Common.motorPower] = 0
        c[Common.lowPass] = 0x01
        return c
    }

    /// Classic rumble emulated by the actuators (haptics select + compatible vibration v2, as SDL
    /// and the kernel do on current firmware). Never sent while the 0x32 stream is running.
    static func rumbleBlock(left: UInt8, right: UInt8) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: commonSize)
        c[Common.valid0] = Valid0.hapticsSelect
        c[Common.valid2] = valid2CompatibleVibration
        c[Common.motorRight] = right
        c[Common.motorLeft] = left
        return c
    }

    private static func put(type: UInt8, params: [UInt8], into c: inout [UInt8], at offset: Int) {
        c[offset] = type
        for i in 0..<10 { c[offset + 1 + i] = i < params.count ? params[i] : 0 }
    }

    // MARK: Transport framing

    /// Wraps a common block into the transport's state report. Bluetooth reports get their sequence
    /// nibble and CRC from `stamp` right before the write.
    static func stateReport(_ common: [UInt8], transport: DualSenseTransport) -> [UInt8] {
        precondition(common.count == commonSize)
        switch transport {
        case .usb:
            return [usbStateID] + common
        case .bluetooth:
            var r = [UInt8](repeating: 0, count: btStateSize)
            r[0] = btStateID
            r[2] = 0x10
            r.replaceSubrange(3..<(3 + commonSize), with: common)
            return r
        }
    }

    /// One 0x32 block. `samples` is up to 64 bytes of interleaved signed 8-bit L/R; the rest is
    /// silence (0).
    static func hapticsReport(_ samples: [Int8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: btHapticsSize)
        r[0] = btHapticsID
        r[2] = 0x91
        r[3] = 0x07
        r[4] = 0xFE
        for i in 5...9 { r[i] = hapticsQueueDepth }
        r[11] = 0x92
        r[12] = 0x40
        for i in 0..<min(samples.count, hapticsBytes) { r[hapticsOffset + i] = UInt8(bitPattern: samples[i]) }
        return r
    }

    /// Stereo S16 → interleaved signed 8-bit, linear against `hapticsFullScale`, clamped.
    static func toSigned8(_ s: Int16) -> Int8 {
        let v = Int32(s) * 127 / hapticsFullScale
        return Int8(clamping: v)
    }

    // MARK: Sequence + CRC (Bluetooth)

    /// Writer-side counters shared by every Bluetooth report to one pad (P5M: one stream per
    /// transport, so 0x31 and 0x32 share the nibble; 0x32 also carries its own byte counter).
    struct Sequence {
        var report: UInt8 = 0
        var audio: UInt8 = 0

        /// Stamps the sequence nibble (and the 0x32 audio counter) and writes the CRC. USB reports
        /// and unknown sizes pass through unchanged.
        mutating func stamp(_ r: inout [UInt8]) {
            guard (r.count == btStateSize && r[0] == btStateID) || (r.count == btHapticsSize && r[0] == btHapticsID)
            else { return }
            r[1] = (report & 0x0F) << 4 | (r[1] & 0x0F)
            report = (report + 1) & 0x0F
            if r[0] == btHapticsID {
                r[10] = audio
                audio &+= 1
            }
            DualSenseReports.sealCRC(&r)
        }
    }

    static func sealCRC(_ r: inout [UInt8]) {
        let end = r.count - 4
        let crc = crc32(r[0..<end], seed: [0xA2])
        r[end] = UInt8(crc & 0xFF)
        r[end + 1] = UInt8((crc >> 8) & 0xFF)
        r[end + 2] = UInt8((crc >> 16) & 0xFF)
        r[end + 3] = UInt8((crc >> 24) & 0xFF)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// zlib CRC32 of `seed` followed by `bytes`.
    static func crc32<C: Collection>(_ bytes: C, seed: [UInt8] = []) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in seed { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
