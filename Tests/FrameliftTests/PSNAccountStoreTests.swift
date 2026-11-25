// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

@MainActor struct PSNAccountStoreTests {
    private var expired: PSNAuthorization {
        PSNAuthorization(accessToken: "fixture-old", refreshToken: "fixture-refresh",
                         expiresAt: Date(timeIntervalSinceNow: -1), accountIDBase64: "AAAAAAAAAAA=", onlineID: nil)
    }

    @Test func pairingSignInIsSavedAndReusedAfterRelaunch() async throws {
        var authorization = expired
        authorization.expiresAt = Date(timeIntervalSinceNow: 3600)
        authorization.onlineID = "fixture-player"
        var saved: PSNAuthorization?
        let store = PSNAccountStore(authorization: nil, save: { saved = $0 }, clear: {}) { _ in
            Issue.record("A valid pairing sign-in should not need refreshing")
            throw CancellationError()
        }
        try store.accept(PSNSignIn.Account(accountIDBase64: authorization.accountIDBase64,
                                         onlineID: authorization.onlineID, authorization: authorization))
        #expect(store.signedIn && store.onlineID == "fixture-player")
        #expect(saved == authorization)
        let restored = PSNAccountStore(authorization: saved, save: { _ in }, clear: {}) { _ in
            Issue.record("The restored sign-in should still be valid")
            throw CancellationError()
        }
        #expect(restored.signedIn)
        #expect(try await restored.accessToken(for: Data(base64Encoded: authorization.accountIDBase64)) == authorization.accessToken)
    }

    @Test func failedSignInSaveDoesNotClaimToBeSignedIn() throws {
        enum FixtureError: Error { case unavailable }
        let store = PSNAccountStore(authorization: nil, save: { _ in throw FixtureError.unavailable }, clear: {})
        #expect(throws: FixtureError.unavailable) {
            try store.accept(PSNSignIn.Account(accountIDBase64: expired.accountIDBase64,
                                             onlineID: nil, authorization: expired))
        }
        #expect(!store.signedIn)
    }

    @Test func concurrentRequestsShareOneTokenRefresh() async throws {
        let calls = RefreshCalls()
        var saves = 0
        let store = PSNAccountStore(authorization: expired, save: { _ in saves += 1 }, clear: {}) { previous in
            await calls.record()
            try await Task.sleep(for: .milliseconds(30))
            var next = previous
            next.accessToken = "fixture-new"
            next.expiresAt = Date(timeIntervalSinceNow: 3600)
            return next
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await store.accessToken() } }
            var tokens: [String] = []
            for try await token in group { tokens.append(token) }
            return tokens
        }
        #expect(tokens.count == 8 && tokens.allSatisfy { $0 == "fixture-new" })
        #expect(await calls.count == 1)
        #expect(saves == 1)
    }

    @Test func storageFailureDoesNotReuseARotatedRefreshToken() async throws {
        enum FixtureError: Error { case unavailable }
        let calls = RefreshCalls()
        let store = PSNAccountStore(authorization: expired, save: { _ in throw FixtureError.unavailable }, clear: {}) { previous in
            await calls.record()
            var next = previous
            next.accessToken = "fixture-new"
            next.expiresAt = Date(timeIntervalSinceNow: 3600)
            return next
        }
        do {
            _ = try await store.accessToken()
            Issue.record("A credential write failure was ignored")
        } catch FixtureError.unavailable {}
        #expect(try await store.accessToken() == "fixture-new")
        #expect(await calls.count == 1)
    }

    @Test func signOutRejectsALateRefreshResponse() async throws {
        let calls = RefreshCalls()
        var saves = 0
        let store = PSNAccountStore(authorization: expired, save: { _ in saves += 1 }, clear: {}) { previous in
            await calls.record()
            try? await Task.sleep(for: .seconds(10))
            return previous
        }
        let request = Task { try await store.accessToken() }
        for _ in 0..<100 {
            if await calls.count > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await calls.count == 1)
        try store.signOut()
        do {
            _ = try await request.value
            Issue.record("A signed-out refresh returned a token")
        } catch is CancellationError {}
        #expect(!store.signedIn && saves == 0)
    }
}

private actor RefreshCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
