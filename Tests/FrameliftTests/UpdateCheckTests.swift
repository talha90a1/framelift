// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct UpdateCheckTests {
    private func body(tag: String, url: String? = nil, draft: Bool = false, prerelease: Bool = false) -> Data {
        let link = url ?? "https://github.com/talha90a1/framelift/releases/tag/\(tag)"
        return Data(#"{"tag_name":"\#(tag)","html_url":"\#(link)","draft":\#(draft),"prerelease":\#(prerelease),"assets":[]}"#.utf8)
    }

    @Test func offersOnlyANewerRelease() throws {
        #expect(try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "v1.1.0"))?.version == "1.1.0")
        #expect(try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "v1.0.0")) == nil)
        #expect(try ReleaseCheck.newer(than: "1.2.0", in: body(tag: "v1.1.9")) == nil)
        // Numbers, not text: 10 is newer than 9.
        #expect(try ReleaseCheck.newer(than: "1.9.0", in: body(tag: "v1.10.0"))?.version == "1.10.0")
        #expect(try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "1.0.1"))?.url.absoluteString
            == "https://github.com/talha90a1/framelift/releases/tag/1.0.1")
    }

    @Test func rejectsWhatIsNotAStableReleaseOfThisRepository() {
        #expect(throws: ReleaseCheck.Invalid.self) { try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "v2.0.0-beta")) }
        #expect(throws: ReleaseCheck.Invalid.self) { try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "v2.0.0", prerelease: true)) }
        #expect(throws: ReleaseCheck.Invalid.self) { try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "v2.0.0", draft: true)) }
        #expect(throws: ReleaseCheck.Invalid.self) {
            try ReleaseCheck.newer(than: "1.0.0", in: body(tag: "v2.0.0", url: "https://example.com/releases/tag/v2.0.0"))
        }
        #expect(throws: (any Error).self) { try ReleaseCheck.newer(than: "1.0.0", in: Data("not json".utf8)) }
    }

    @Test func parsesOnlyPlainVersions() {
        #expect(ReleaseCheck.version("v1.2.3") == [1, 2, 3])
        #expect(ReleaseCheck.version("1.2.3") == [1, 2, 3])
        for bad in ["1.2", "1.2.3.4", "v1.-2.3", "1.+2.3", "1..3", "", "v", "1.2.3a", "99999999999999999999.0.0"] {
            #expect(ReleaseCheck.version(bad) == nil, "\(bad)")
        }
    }
}

struct SessionRetryPolicyTests {
    @Test func waitsForThePS5ToReleaseItsSession() {
        let policy = SessionRetryPolicy.self
        #expect((1...3).map { policy.seconds(.start, retry: $0) } == [1, 2, 4])
        #expect((1...3).map { policy.seconds(.inUse, retry: $0) } == [10, 20, 40])
        #expect((1...3).map { policy.seconds(.afterLive, retry: $0) } == [20, 30, 40])
        #expect(policy.seconds(.afterLive, retry: 0) == 20)
        #expect(policy.seconds(.afterLive, retry: 9) == 40)
    }

    @Test func inUseWinsOverAStreamThatWasPlaying() {
        #expect(SessionRetryPolicy.wait(consoleHoldsSession: true, wasPlaying: true) == .inUse)
        #expect(SessionRetryPolicy.wait(consoleHoldsSession: false, wasPlaying: true) == .afterLive)
        #expect(SessionRetryPolicy.wait(consoleHoldsSession: false, wasPlaying: false) == .start)
    }

    @Test func inUseIsRetriedOnlyWhenItIsProbablyOurSession() {
        let inUse = SessionRetryPolicy.QuitReason.remotePlayInUse.rawValue
        #expect(SessionRetryPolicy.isTransient(quitReason: inUse) == false)
        #expect(SessionRetryPolicy.isTransient(quitReason: inUse, ourSessionLikely: true))
        #expect(SessionRetryPolicy.consoleHoldsSession(quitReason: inUse))
        #expect(SessionRetryPolicy.isTransient(quitReason: SessionRetryPolicy.QuitReason.stopped.rawValue, ourSessionLikely: true) == false)
    }
}
