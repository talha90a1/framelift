// SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation
import Security
import FrameliftCore

struct PSNAuthorization: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
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
    private var deviceRequest: Int?
    private var refreshTask: (id: UUID, task: Task<PSNAuthorization, Error>)?
    private let clearAuthorization: () throws -> Void
    private let saveAuthorization: (PSNAuthorization) throws -> Void
    private let refreshAuthorization: @Sendable (PSNAuthorization) async throws -> PSNAuthorization

    init(authorization: PSNAuthorization? = PSNKeychain.load(),
         save: @escaping (PSNAuthorization) throws -> Void = PSNKeychain.save,
         clear: @escaping () throws -> Void = PSNKeychain.clear,
         refresh: @escaping @Sendable (PSNAuthorization) async throws -> PSNAuthorization = { try await PSNSignIn.refresh($0) }) {
        self.authorization = authorization
        clearAuthorization = clear
        saveAuthorization = save
        refreshAuthorization = refresh
        signedIn = authorization != nil
        onlineID = authorization?.onlineID
    }

    func accept(_ account: PSNSignIn.Account) throws {
        guard let authorization = account.authorization else { throw PSNSignIn.Failure.badResponse }
        try saveAuthorization(authorization)
        refreshTask?.task.cancel()
        refreshTask = nil
        self.authorization = authorization
        signedIn = true
        onlineID = authorization.onlineID
        devices = []
        generation += 1
    }

    func signOut() throws {
        try clearAuthorization()
        generation += 1
        refreshTask?.task.cancel()
        refreshTask = nil
        authorization = nil
        signedIn = false
        onlineID = nil
        devices = []
        deviceRequest = nil
        loading = false
    }

    func accessToken(for accountID: Data? = nil) async throws -> String {
        guard var current = authorization else { throw PSNSignIn.Failure.signInRequired }
        if let accountID, Data(base64Encoded: current.accountIDBase64) != accountID {
            throw PSNSignIn.Failure.differentAccount
        }
        if current.expiresAt.timeIntervalSinceNow < 60 {
            let before = generation
            let pending: (id: UUID, task: Task<PSNAuthorization, Error>)
            if let active = refreshTask { pending = active }
            else {
                let refresh = refreshAuthorization
                let previous = current
                pending = (UUID(), Task { try await refresh(previous) })
                refreshTask = pending
            }
            defer { if refreshTask?.id == pending.id { refreshTask = nil } }
            current = try await pending.task.value
            guard before == generation, authorization != nil else { throw CancellationError() }
            if authorization != current {
                authorization = current
                try saveAuthorization(current)
            }
        }
        return current.accessToken
    }

    func refreshDevices() async throws {
        let before = generation
        guard deviceRequest != before else { return }
        deviceRequest = before
        loading = true
        defer {
            if deviceRequest == before { deviceRequest = nil; loading = false }
        }
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
