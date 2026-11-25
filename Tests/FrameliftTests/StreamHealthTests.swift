// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import Framelift

struct StreamHealthTests {
    @Test func reconnectsAfterMediaStopsEvenIfTheCoreStillSaysConnected() {
        let arrival = HostClock.ticks(seconds: 100)
        #expect(!StreamHealth.videoTimedOut(lastArrival: arrival, now: HostClock.ticks(seconds: 104.9)))
        #expect(StreamHealth.videoTimedOut(lastArrival: arrival, now: HostClock.ticks(seconds: 105)))
        #expect(!StreamHealth.videoTimedOut(lastArrival: 0, now: HostClock.now()))
        #expect(!StreamHealth.videoTimedOut(lastArrival: arrival, now: arrival - 1))
    }
}
