// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct PSNSignInTests {
    @Test func extractsCodeOnlyFromRemotePlayRedirect() {
        let ok = URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=AbC123&cid=x")!
        #expect(PSNSignIn.code(fromRedirect: ok) == "AbC123")
        let other = URL(string: "https://evil.example.com/remoteplay/redirect?code=AbC123")!
        #expect(PSNSignIn.code(fromRedirect: other) == nil)
        let noCode = URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?error=denied")!
        #expect(PSNSignIn.code(fromRedirect: noCode) == nil)
        #expect(PSNSignIn.code(fromRedirect: URL(string: "http://remoteplay.dl.playstation.net/remoteplay/redirect?code=x")!) == nil)
        #expect(PSNSignIn.code(fromRedirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect-other?code=x")!) == nil)
    }

    @Test func loginURLTargetsSonyWithRemotePlayRedirect() {
        let c = URLComponents(url: PSNSignIn.loginURL, resolvingAgainstBaseURL: false)!
        #expect(c.host == "auth.api.sonyentertainmentnetwork.com")
        #expect(c.queryItems?.first { $0.name == "redirect_uri" }?.value == "https://remoteplay.dl.playstation.net/remoteplay/redirect")
        #expect(c.queryItems?.first { $0.name == "scope" }?.value?.contains("sessionManager:remotePlaySession.system.update") == true)
        #expect(c.queryItems?.first { $0.name == "duid" }?.value?.count == 48)
    }

    @Test func accountIDEncodingMatchesPSNAccountDecoder() {
        // Same encoding as chiaki's script: 8-byte little-endian user id, Base64.
        var le = UInt64(1_234_567_890_123_456_789).littleEndian
        let b64 = Data(bytes: &le, count: 8).base64EncodedString()
        #expect(PSNAccount.decode(base64OrDecimal: b64) == PSNAccount.decode(base64OrDecimal: "1234567890123456789"))
    }

    @Test func tokenPayloadNeedsAnExpiryAndRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 100)
        let token = try PSNSignIn.parseAuthorization(["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600], accountID: "fixture-id", onlineID: nil, now: now)
        #expect(token.expiresAt == Date(timeIntervalSince1970: 3700))
        #expect(!String(describing: token).contains("fixture-access"))
        #expect(throws: (any Error).self) {
            try PSNSignIn.parseAuthorization(["access_token": "fixture", "expires_in": 0], accountID: "fixture-id", onlineID: nil)
        }
    }
}
