// SPDX-License-Identifier: AGPL-3.0-only
// Maps PS5 adaptive-trigger effects (raw DualSense HID trigger block: type byte + 10 parameter bytes)
// onto GCDualSenseAdaptiveTrigger. Byte layout per Nielk1's TriggerEffectGenerator (MIT). Zones 0...9
// map to positions zone/9; GC frequency is normalized, so Hz is mapped as Hz / 255 (an assumption).
import Foundation
import GameController

enum TriggerEffectMapper {
    static func apply(type: UInt8, params raw: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) {
        var p = [UInt8](repeating: 0, count: 10)
        for i in 0..<min(10, raw.count) { p[i] = raw[i] }
        let zones = UInt16(p[0]) | UInt16(p[1]) << 8

        switch type {
        case 0x01:
            trigger.setModeFeedbackWithStartPosition(unit(p[0]), resistiveStrength: unit(p[1]))
        case 0x02:
            weapon(trigger, start: unit(p[0]), end: unit(p[1]), strength: unit(p[2]))
        case 0x06:
            trigger.setModeVibrationWithStartPosition(unit(p[2]), amplitude: unit(p[1]), frequency: unit(p[0]))
        case 0x11:
            trigger.setModeFeedbackWithStartPosition(unit(p[0]), resistiveStrength: clamp(Float(p[1]) / 10))
        case 0x12:
            weapon(trigger, start: unit(p[0]), end: unit(p[1]), strength: clamp(Float(p[2]) / 10))
        case 0x21:
            let packed = le32(p, 2)
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            fill(&strengths.values) { zoneLevel(zones: zones, packed: packed, zone: $0) }
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case 0x25, 0x22:
            guard let (start, end) = zoneSpan(zones) else { trigger.setModeOff(); return }
            weapon(trigger, start: Float(start) / 9, end: Float(end) / 9, strength: Float(p[2] & 7 + 1) / 8)
        case 0x26:
            let packed = le32(p, 2)
            var amplitudes = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            fill(&amplitudes.values) { zoneLevel(zones: zones, packed: packed, zone: $0) }
            trigger.setModeVibration(amplitudes: amplitudes, frequency: unit(p[8]))
        case 0x23:
            guard let (start, _) = zoneSpan(zones) else { trigger.setModeOff(); return }
            trigger.setModeVibrationWithStartPosition(Float(start) / 9, amplitude: 0.6, frequency: unit(p[3]))
        case 0x27:
            guard let (start, _) = zoneSpan(zones) else { trigger.setModeOff(); return }
            let amp = max(Float(max(p[2] & 7, (p[2] >> 3) & 7)) / 7, 0.15)
            trigger.setModeVibrationWithStartPosition(Float(start) / 9, amplitude: amp, frequency: unit(p[3]))
        default:
            trigger.setModeOff()
        }
    }

    private static func weapon(_ t: GCDualSenseAdaptiveTrigger, start: Float, end: Float, strength: Float) {
        let s = clamp(start)
        t.setModeWeaponWithStartPosition(s, endPosition: max(clamp(end), min(s + 0.05, 1)), resistiveStrength: strength)
    }

    private static func unit(_ b: UInt8) -> Float { Float(b) / 255 }
    private static func clamp(_ v: Float) -> Float { min(max(v, 0), 1) }
    private static func le32(_ p: [UInt8], _ o: Int) -> UInt32 {
        UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
    }

    /// Level of one zone: its 3-bit value + 1 out of 8 when the zone is active, else 0.
    private static func zoneLevel(zones: UInt16, packed: UInt32, zone: Int) -> Float {
        guard zones & (1 << zone) != 0 else { return 0 }
        return Float((packed >> (3 * UInt32(zone))) & 7 + 1) / 8
    }

    /// Lowest and highest set zone bit (0...9).
    private static func zoneSpan(_ zones: UInt16) -> (Int, Int)? {
        let z = zones & 0x3FF
        guard z != 0 else { return nil }
        return (z.trailingZeroBitCount, 15 - z.leadingZeroBitCount)
    }

    /// Writes 10 positional values into GC's imported C tuple.
    private static func fill<T>(_ tuple: inout T, _ value: (Int) -> Float) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<min(10, floats.count) { floats[i] = value(i) }
        }
    }
}
