// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import Framelift

struct RepeatedFrameCadenceTests {
    @Test(arguments: [true, false])
    func keepsBothPhasesWithoutAlternation(nearRepeat: Bool) {
        var cadence = RepeatedFrameCadence()
        for _ in 0..<120 {
            let discard = cadence.observe(nearRepeat: nearRepeat)
            #expect(!discard)
            #expect(!cadence.isHalfRate)
        }
    }

    @Test(arguments: [0, 1])
    func dropsOnlyTheRepeatedPhaseAfterQualification(repeatPhase: Int) {
        var cadence = RepeatedFrameCadence()
        for index in 0..<96 {
            let nearRepeat = index % 2 == repeatPhase
            let discard = cadence.observe(nearRepeat: nearRepeat)
            #expect(cadence.isHalfRate == (index >= 31))
            #expect(discard == (index >= 31 && nearRepeat))
        }
    }

    @Test func keepsConsecutiveSimilarFramesAndReleasesTheCadence() {
        var cadence = RepeatedFrameCadence()
        for index in 0..<32 {
            _ = cadence.observe(nearRepeat: index % 2 == 1)
        }
        #expect(cadence.isHalfRate)

        for _ in 0..<8 {
            let discard = cadence.observe(nearRepeat: true)
            #expect(!discard)
        }
        // Hysteresis: released once the repeats have mostly stopped.
        for _ in 0..<32 {
            let discard = cadence.observe(nearRepeat: false)
            #expect(!discard)
        }
        #expect(!cadence.isHalfRate)
    }
}
