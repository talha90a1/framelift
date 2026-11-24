// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import Testing
@testable import Framelift

struct AppleLLFITeardownTests {
    @Test(.enabled(if: AppleLLFIInterpolator.isSupported))
    func releasesInterpolatorFromVideoToolboxCompletion() throws {
        let frame = try #require(
            OfflineFrameGenHarness.makeBuffer(Data(repeating: 128, count: 1280 * 720 * 3 / 2), w: 1280, h: 720))
        let owner = Owner()
        owner.prepare(frame)

        let timeout = Date().addingTimeInterval(12)
        while !owner.isReady(frame), Date() < timeout {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try #require(owner.isReady(frame))

        let submitted = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        owner.submit(frame, submitted: submitted, finished: finished)
        submitted.signal()

        try #require(finished.wait(timeout: .now() + 8) == .success)
        #expect(owner.releasedAfterSubmission)
    }

    private final class Owner {
        private var interpolator: AppleLLFIInterpolator? = AppleLLFIInterpolator(keepWarm: true)
        private(set) var releasedAfterSubmission = false

        func prepare(_ frame: CVPixelBuffer) {
            interpolator?.prepare(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        }

        func isReady(_ frame: CVPixelBuffer) -> Bool {
            interpolator?.isReady(for: frame) == true
        }

        func submit(_ frame: CVPixelBuffer, submitted: DispatchSemaphore, finished: DispatchSemaphore) {
            interpolator?.interpolate(previous: frame, current: frame) { _ in
                self.releasedAfterSubmission = submitted.wait(timeout: .now() + 2) == .success
                self.interpolator = nil
                finished.signal()
            }
        }
    }
}
