// SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation
import Security
import VeyraCore

struct PSNAuthorization: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var accountIDBase64: String
    var onlineID: String?
    var description: String { "PSNAuthorization(<redacted>)" }
    var debugDescription: String { description }
}

enum PSNKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.framelift.mac.psn",
         kSecAttrAccount as String: "remote-play"]
    }

    static func load() -> PSNAuthorization? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PSNAuthorization.self, from: data)
    }

    static func save(_ authorization: PSNAuthorization) throws {
        let data = try JSONEncoder().encode(authorization)
        let attributes = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Couldn't update PlayStation sign-in in Keychain. Try signing in again." }
    }
}

struct PSNDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var enabled: Bool
}

@MainActor final class PSNAccountStore: ObservableObject {
    @Published private(set) var signedIn = false
    @Published private(set) var onlineID: String?
    @Published private(set) var devices: [PSNDevice] = []
    @Published private(set) var loading = false
    private var authorization: PSNAuthorization?
    private var generation = 0

    init() {
        authorization = PSNKeychain.load()
        signedIn = authorization != nil
        onlineID = authorization?.onlineID
    }

    func accept(_ account: PSNSignIn.Account) async throws {
        guard let authorization = account.authorization else { throw PSNSignIn.Failure.badResponse }
        try PSNKeychain.save(authorization)
        self.authorization = authorization
        signedIn = true
        onlineID = authorization.onlineID
        generation += 1
        try await refreshDevices()
    }

    func signOut() throws {
        try PSNKeychain.clear()
        generation += 1
        authorization = nil
        signedIn = false
        onlineID = nil
        devices = []
    }

    func accessToken(for accountID: Data? = nil) async throws -> String {
        guard var current = authorization else { throw PSNSignIn.Failure.signInRequired }
        if let accountID, Data(base64Encoded: current.accountIDBase64) != accountID {
            throw PSNSignIn.Failure.differentAccount
        }
        if current.expiresAt.timeIntervalSinceNow < 60 {
            let before = generation
            current = try await PSNSignIn.refresh(current)
            guard before == generation, authorization != nil else { throw CancellationError() }
            try PSNKeychain.save(current)
            authorization = current
        }
        return current.accessToken
    }

    func refreshDevices() async throws {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let before = generation
        let token = try await accessToken()
        let result = await BridgeInterop.run { () -> (Int32, [PSNDevice]) in
            var native = [VRPSNDevice](repeating: VRPSNDevice(), count: 32)
            let count = vr_psn_list_devices(token, &native, Int32(native.count))
            guard count >= 0 else { return (count, []) }
            return (0, native.prefix(Int(count)).map {
                PSNDevice(id: BridgeInterop.hex(BridgeInterop.data(of: $0.uid)),
                          name: BridgeInterop.string(of: $0.name), enabled: $0.remote_play_enabled)
            })
        }
        guard before == generation else { return }
        guard result.0 == 0 else { throw RemotePlaySessionError(code: -2100) }
        devices = result.1
    }
}
