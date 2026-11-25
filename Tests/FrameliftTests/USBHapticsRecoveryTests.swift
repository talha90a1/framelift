// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct USBHapticsRecoveryTests {
    private final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var now: Double = 0
        var attempts = 0
        var stopped = false
    }

    private final class Device: USBHapticsDevice, @unchecked Sendable {
        let fixture: Fixture
        init(_ fixture: Fixture) { self.fixture = fixture }
        func enqueue(_ samples: [Int16]) {}
        func stop() { fixture.lock.withLock { fixture.stopped = true } }
    }

    @Test func retriesAfterTheAudioDeviceAppears() {
        let fixture = Fixture()
        let firstAttempt = DispatchSemaphore(value: 0)
        let secondAttempt = DispatchSemaphore(value: 0)
        let recovery = USBHapticsRecovery(clock: { fixture.lock.withLock { fixture.now } }) {
            let count = fixture.lock.withLock { fixture.attempts += 1; return fixture.attempts }
            if count == 1 { firstAttempt.signal(); return nil }
            secondAttempt.signal()
            return Device(fixture)
        }
        #expect(recovery.poll() == nil)
        #expect(firstAttempt.wait(timeout: .now() + 1) == .success)
        for _ in 0..<5 { #expect(recovery.poll() == nil) }
        #expect(fixture.lock.withLock { fixture.attempts } == 1)
        fixture.lock.withLock { fixture.now = 1 }
        for _ in 0..<100 {
            if fixture.lock.withLock({ fixture.attempts }) == 2 { break }
            _ = recovery.poll()
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(secondAttempt.wait(timeout: .now() + 1) == .success)
        var device: (any USBHapticsDevice)?
        for _ in 0..<100 {
            device = recovery.poll()
            if device != nil { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(device != nil)
        fixture.lock.withLock { fixture.now = 10 }
        #expect(recovery.poll() == nil)
        #expect(fixture.lock.withLock { fixture.attempts } == 2)
        device?.stop()
        recovery.stop()
    }

    @Test func closingWhileOpeningDisposesTheLateDevice() {
        let fixture = Fixture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let recovery = USBHapticsRecovery {
            entered.signal()
            _ = release.wait(timeout: .now() + 1)
            return Device(fixture)
        }
        #expect(recovery.poll() == nil)
        #expect(entered.wait(timeout: .now() + 1) == .success)
        recovery.stop()
        release.signal()
        for _ in 0..<100 where !fixture.lock.withLock({ fixture.stopped }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(fixture.lock.withLock { fixture.stopped })
        #expect(recovery.poll() == nil)
    }
}
