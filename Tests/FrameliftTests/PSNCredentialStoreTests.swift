// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Testing
@testable import Framelift

struct PSNCredentialStoreTests {
    private struct TestCryptor: PSNCredentialCryptor {
        let key = SymmetricKey(size: .bits256)
        func seal(_ data: Data) throws -> Data { try #require(AES.GCM.seal(data, using: key).combined) }
        func open(_ data: Data) throws -> Data { try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
    }

    private var authorization: PSNAuthorization {
        PSNAuthorization(
            accessToken: "fixture-access-secret", refreshToken: "fixture-refresh-secret",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000), accountIDBase64: "AAAAAAAAAAA=", onlineID: "fixture-player")
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("framelift-credentials-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savesEncryptedCredentialsWithPrivatePermissionsAndRestoresAfterRelaunch() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = TestCryptor()
        let store = PSNCredentialStore(directory: directory, cryptor: cipher)
        #expect(try store.load() == nil)
        try store.save(authorization)
        let file = directory.appendingPathComponent("psn.enc")
        let bytes = try Data(contentsOf: file)
        #expect(bytes.range(of: Data(authorization.accessToken.utf8)) == nil)
        #expect(bytes.range(of: Data(authorization.refreshToken.utf8)) == nil)
        #expect(try PSNCredentialStore(directory: directory, cryptor: cipher).load() == authorization)
        let fm = FileManager.default
        #expect((try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var refreshed = authorization
        refreshed.accessToken = "fixture-rotated-access"
        refreshed.refreshToken = "fixture-rotated-refresh"
        try store.save(refreshed)
        #expect(try store.load() == refreshed)
        #expect(try fm.contentsOfDirectory(atPath: directory.path) == ["psn.enc"])
        #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.clear()
        #expect(try PSNCredentialStore(directory: directory, cryptor: cipher).load() == nil)
        #expect(!fm.fileExists(atPath: file.path))
        try store.clear()
    }

    @Test func corruptCredentialsArePreservedAndNeverLoadedAsPlaintext() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PSNCredentialStore(directory: directory, cryptor: TestCryptor())
        _ = try store.load()
        let file = directory.appendingPathComponent("psn.enc")
        let data = try JSONEncoder().encode(authorization)
        try data.write(to: file)
        do {
            _ = try store.load()
            Issue.record("Plaintext credentials were accepted")
        } catch {
            #expect(!error.localizedDescription.contains(authorization.accessToken))
        }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func symlinksAreNotFollowedAndNewSignInReplacesTheLinkOnly() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PSNCredentialStore(directory: root.appendingPathComponent("Credentials"), cryptor: TestCryptor())
        _ = try store.load()
        let outside = root.appendingPathComponent("unrelated")
        let sentinel = Data("fixture-unrelated-data".utf8)
        try sentinel.write(to: outside)
        let link = store.directory.appendingPathComponent("psn.enc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try store.load() }
        try store.save(authorization)
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(try store.load() == authorization)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
    }

    @Test func failedReplacementLeavesThePreviousCredentialFileIntact() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = TestCryptor()
        let store = PSNCredentialStore(directory: directory, cryptor: cipher)
        try store.save(authorization)
        let file = directory.appendingPathComponent("psn.enc")
        let original = try Data(contentsOf: file)
        var oversized = authorization
        oversized.accessToken = String(repeating: "x", count: 70_000)
        #expect(throws: (any Error).self) { try store.save(oversized) }
        #expect(try Data(contentsOf: file) == original)
        #expect(try store.load() == authorization)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["psn.enc"])
    }

    @Test(.enabled(if: SecureEnclave.isAvailable))
    func hardwareEncryptionRestoresWithoutRawKeyAndRejectsTampering() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try PSNCredentialStore(directory: directory).save(authorization)
        #expect(try PSNCredentialStore(directory: directory).load() == authorization)
        let saved = try Data(contentsOf: directory.appendingPathComponent("psn.enc"))
        #expect(saved.range(of: Data(authorization.refreshToken.utf8)) == nil)
        let cipher = DeviceCredentialCryptor()
        let plaintext = try JSONEncoder().encode(authorization)
        let data = try cipher.seal(plaintext)
        #expect(data.range(of: Data(authorization.accessToken.utf8)) == nil)
        #expect(try DeviceCredentialCryptor().open(data) == plaintext)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var encrypted = try #require((object["ciphertext"] as? String).flatMap { Data(base64Encoded: $0) })
        encrypted[encrypted.startIndex] ^= 1
        object["ciphertext"] = encrypted.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try cipher.open(tampered) }
        object["version"] = 99
        #expect(throws: (any Error).self) { try cipher.open(JSONSerialization.data(withJSONObject: object)) }
        let other = try #require(JSONSerialization.jsonObject(with: cipher.seal(plaintext)) as? [String: Any])
        object["version"] = 1
        object["protectedKey"] = other["protectedKey"]
        #expect(throws: (any Error).self) { try cipher.open(JSONSerialization.data(withJSONObject: object)) }
    }

    @MainActor @Test func accountStorePersistsSignInAndSignOutThroughTheCredentialFile() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = PSNCredentialStore(directory: directory, cryptor: TestCryptor())
        let account = PSNAccountStore(credentials: credentials)
        #expect(!account.signedIn && account.credentialError == nil)
        try account.accept(
            PSNSignIn.Account(
                accountIDBase64: authorization.accountIDBase64,
                onlineID: authorization.onlineID, authorization: authorization))
        let relaunched = PSNAccountStore(credentials: credentials)
        #expect(relaunched.signedIn && relaunched.onlineID == authorization.onlineID)
        try relaunched.signOut()
        #expect(!PSNAccountStore(credentials: credentials).signedIn)
    }

    @MainActor @Test func refreshedTokenIsPersistedAndCorruptionIsVisibleWithoutLeakingTokens() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = PSNCredentialStore(directory: directory, cryptor: TestCryptor())
        var expired = authorization
        expired.expiresAt = .distantPast
        try credentials.save(expired)
        let account = PSNAccountStore(
            authorization: try credentials.load(), save: credentials.save,
            clear: credentials.clear
        ) { previous in
            var next = previous
            next.accessToken = "fixture-refreshed-token"
            next.refreshToken = "fixture-rotated-refresh-token"
            next.expiresAt = .distantFuture
            return next
        }
        #expect(try await account.accessToken() == "fixture-refreshed-token")
        #expect(try credentials.load()?.refreshToken == "fixture-rotated-refresh-token")
        #expect(try await PSNAccountStore(credentials: credentials).accessToken() == "fixture-refreshed-token")
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("psn.enc"))
        let corrupted = PSNAccountStore(credentials: credentials)
        #expect(!corrupted.signedIn && corrupted.credentialError != nil)
        #expect(corrupted.credentialError?.contains("fixture") == false)
        try credentials.save(authorization)
        corrupted.restoreSavedSignIn()
        #expect(corrupted.signedIn && corrupted.credentialError == nil)
    }
}
