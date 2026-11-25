// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct ControllerSetupTests {
    @Test func remembersTheLastConnectedController() {
        let suite = testDefaultsSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaults(suite) }
        let controller = ControllerIdentity(name: "DualSense Wireless Controller", kind: .dualSense)

        #expect(ControllerIdentity.stored(in: defaults) == nil)
        controller.save(in: defaults)
        #expect(ControllerIdentity.stored(in: defaults) == controller)
        ControllerIdentity.clear(in: defaults)
        #expect(ControllerIdentity.stored(in: defaults) == nil)
    }

    @Test func canceledRemovalDoesNotStartBluetoothWork() async {
        let device = PairedDualSense(id: "00-00-00-00-00-00", name: "DualSense", isConnected: false)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await device.perform(.unpair)
        }
        do {
            try await operation.value
            Issue.record("Canceled controller removal succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("Canceled removal reached Bluetooth work: \(error)")
        }
    }

    @Test func pairingDemoFlashesAfterHoldingBothButtons() {
        #expect(DualSensePairingDemo.loopTime(-1) == 0)
        #expect(DualSensePairingDemo.loopTime(5.5) == 0)
        #expect(DualSensePairingDemo.press(at: 0) == (create: 0, ps: 0))
        #expect(DualSensePairingDemo.press(at: 0.7) == (create: 1, ps: 0))
        #expect(DualSensePairingDemo.press(at: 1.2) == (create: 1, ps: 1))
        #expect(!DualSensePairingDemo.lightFlashes(at: 4.19))
        #expect(DualSensePairingDemo.lightFlashes(at: DualSensePairingDemo.heldPose))
        #expect(!DualSensePairingDemo.lightFlashes(at: 4.42))
        #expect(DualSensePairingDemo.lightFlashes(at: 4.52))
        #expect(DualSensePairingDemo.press(at: 5.15) == (create: 0, ps: 0))
    }
}
