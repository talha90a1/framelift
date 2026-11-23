// SPDX-License-Identifier: AGPL-3.0-only
// Byte layout of the DualSense output reports (Sources/Framelift/Input/DualSenseReports.swift).
import Foundation
import Testing
@testable import Framelift

@Suite struct DualSenseReportsTests {
    @Test func crc32MatchesZlibCheckValue() {
        #expect(DualSenseReports.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(DualSenseReports.crc32([UInt8]()) == 0)
    }

    @Test func crcCoversA2SeedAndIsLittleEndian() {
        var seq = DualSenseReports.Sequence()
        var r = DualSenseReports.stateReport(DualSenseReports.powerSetupBlock(), transport: .bluetooth)
        seq.stamp(&r)
        let expected = DualSenseReports.crc32([0xA2] + r[0..<74])
        let stored = UInt32(r[74]) | UInt32(r[75]) << 8 | UInt32(r[76]) << 16 | UInt32(r[77]) << 24
        #expect(stored == expected)
        #expect(DualSenseReports.crc32(r[0..<74], seed: [0xA2]) == expected)
    }

    @Test func sequenceNibbleIsSharedAndWraps() {
        var seq = DualSenseReports.Sequence()
        var nibbles: [UInt8] = []
        for i in 0..<18 {
            var r = i.isMultiple(of: 2)
                ? DualSenseReports.hapticsReport([])
                : DualSenseReports.stateReport(DualSenseReports.powerSetupBlock(), transport: .bluetooth)
            seq.stamp(&r)
            nibbles.append(r[1] >> 4)
            #expect(r[1] & 0x0F == 0)
        }
        #expect(nibbles == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1])
    }

    @Test func audioCounterOnlyOnHapticsReports() {
        var seq = DualSenseReports.Sequence()
        var a = DualSenseReports.hapticsReport([])
        var s = DualSenseReports.stateReport(DualSenseReports.powerSetupBlock(), transport: .bluetooth)
        var b = DualSenseReports.hapticsReport([])
        seq.stamp(&a); seq.stamp(&s); seq.stamp(&b)
        #expect(a[10] == 0)
        #expect(b[10] == 1)
        #expect(s[10] == 0)
    }

    @Test func usbReportsAreNotStamped() {
        var seq = DualSenseReports.Sequence()
        let original = DualSenseReports.stateReport(DualSenseReports.powerSetupBlock(), transport: .usb)
        var r = original
        seq.stamp(&r)
        #expect(r == original)
        #expect(seq.report == 0)
    }

    private let left: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    private let right: [UInt8] = [11, 12, 13, 14, 15, 16, 17, 18, 19, 20]

    @Test func bluetoothTriggerSlots() {
        let r = DualSenseReports.stateReport(
            DualSenseReports.triggerBlock(typeLeft: 0x21, left: left, typeRight: 0x26, right: right), transport: .bluetooth)
        #expect(r.count == 78)
        #expect(r[0] == 0x31)
        #expect(r[2] == 0x10)
        #expect(r[3] == 0x0C)        // valid0: right 0x04 | left 0x08
        #expect(r[4] == 0)           // valid1 untouched
        #expect(r[13] == 0x26)       // right first
        #expect(Array(r[14...23]) == right)
        #expect(r[24] == 0x21)
        #expect(Array(r[25...34]) == left)
        #expect(r[5] == 0 && r[6] == 0)
    }

    @Test func usbTriggerSlots() {
        let r = DualSenseReports.stateReport(
            DualSenseReports.triggerBlock(typeLeft: 0x21, left: left, typeRight: 0x26, right: right), transport: .usb)
        #expect(r.count == 48)
        #expect(r[0] == 0x02)
        #expect(r[1] == 0x0C)
        #expect(r[11] == 0x26)
        #expect(Array(r[12...21]) == right)
        #expect(r[22] == 0x21)
        #expect(Array(r[23...32]) == left)
    }

    @Test func shortParamsArePaddedWithZeros() {
        let c = DualSenseReports.triggerBlock(typeLeft: 0x01, left: [9], typeRight: 0x05, right: [])
        #expect(c[21] == 0x01 && c[22] == 9)
        #expect(c[23...31].allSatisfy { $0 == 0 })
        #expect(c[10] == 0x05 && c[11...20].allSatisfy { $0 == 0 })
    }

    @Test func powerSetupBluetoothOffsets() {
        let r = DualSenseReports.stateReport(DualSenseReports.powerSetupBlock(), transport: .bluetooth)
        #expect(r[3] == 0)           // no rumble/trigger bits
        #expect(r[4] == 0x62)        // power save 0x02 | low-pass 0x20 | motor power 0x40
        #expect(r[12] == 0)
        #expect(r[39] == 0)
        #expect(r[42] == 0x01)
    }

    @Test func rumbleBluetoothOffsets() {
        let r = DualSenseReports.stateReport(DualSenseReports.rumbleBlock(left: 200, right: 50), transport: .bluetooth)
        #expect(r[3] == 0x02)
        #expect(r[41] == 0x04)
        #expect(r[5] == 50)          // right motor
        #expect(r[6] == 200)         // left motor
    }

    @Test func hapticsReportPacksOneBlock() {
        var samples = [Int8](repeating: 0, count: 64)
        for i in 0..<64 { samples[i] = Int8(i - 32) }
        var seq = DualSenseReports.Sequence()
        var r = DualSenseReports.hapticsReport(samples)
        seq.stamp(&r)
        #expect(r.count == 142)
        #expect(r[0] == 0x32)
        #expect(Array(r[2...4]) == [0x91, 0x07, 0xFE])
        #expect(Array(r[5...9]) == [16, 16, 16, 16, 16])
        #expect(r[11] == 0x92 && r[12] == 0x40)
        #expect(Array(r[13..<77]).map { Int8(bitPattern: $0) } == samples)
        #expect(r[77..<138].allSatisfy { $0 == 0 })
        #expect(DualSenseReports.crc32(r[0..<138], seed: [0xA2])
            == UInt32(r[138]) | UInt32(r[139]) << 8 | UInt32(r[140]) << 16 | UInt32(r[141]) << 24)
    }

    @Test func shortHapticsTailIsSilencePadded() {
        let r = DualSenseReports.hapticsReport([5, -5])
        #expect(r[13] == 5 && Int8(bitPattern: r[14]) == -5)
        #expect(r[15..<77].allSatisfy { $0 == 0 })
    }

    @Test func s16ToSigned8IsLinearAndClamped() {
        #expect(DualSenseReports.toSigned8(0) == 0)
        #expect(DualSenseReports.toSigned8(16384) == 127)
        #expect(DualSenseReports.toSigned8(-16384) == -127)
        #expect(DualSenseReports.toSigned8(8192) == 63)
        #expect(DualSenseReports.toSigned8(.max) == 127)
        #expect(DualSenseReports.toSigned8(.min) == -128)
    }

    @Test func feedbackModeDefaultsToExact() {
        let defaults = UserDefaults(suiteName: "framelift.tests.dualsense.\(UUID().uuidString)")!
        #expect(DualSenseFeedbackMode.stored(defaults) == .exact)
        defaults.set("compatible", forKey: DualSenseFeedbackMode.defaultsKey)
        #expect(DualSenseFeedbackMode.stored(defaults) == .compatible)
    }
}
