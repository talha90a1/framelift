// SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation
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
    @Published private(set) var credentialError: String?
    private var authorization: PSNAuthorization?
    private var generation = 0
    private var deviceRequest: Int?
    private var refreshTask: (id: UUID, task: Task<PSNAuthorization, Error>)?
    private let clearAuthorization: () throws -> Void
    private let saveAuthorization: (PSNAuthorization) throws -> Void
    private let refreshAuthorization: @Sendable (PSNAuthorization) async throws -> PSNAuthorization
    private var loadAuthorization: (() throws -> PSNAuthorization?)?

    convenience init() { self.init(credentials: .standard) }

    convenience init(credentials: PSNCredentialStore) {
        self.init(authorization: nil, save: credentials.save, clear: credentials.clear)
        loadAuthorization = credentials.load
        restoreSavedSignIn()
    }

    init(authorization: PSNAuthorization?,
         save: @escaping (PSNAuthorization) throws -> Void = PSNCredentialStore.standard.save,
         clear: @escaping () throws -> Void = PSNCredentialStore.standard.clear,
         refresh: @escaping @Sendable (PSNAuthorization) async throws -> PSNAuthorization = { try await PSNSignIn.refresh($0) }) {
        self.authorization = authorization
        clearAuthorization = clear
        saveAuthorization = save
        refreshAuthorization = refresh
        signedIn = authorization != nil
        onlineID = authorization?.onlineID
    }

    func restoreSavedSignIn() {
        guard !signedIn, let loadAuthorization else { return }
        do {
            authorization = try loadAuthorization()
            signedIn = authorization != nil
            onlineID = authorization?.onlineID
            credentialError = nil
        } catch { credentialError = error.localizedDescription }
    }

    func accept(_ account: PSNSignIn.Account) throws {
        guard let authorization = account.authorization else { throw PSNSignIn.Failure.badResponse }
        try saveAuthorization(authorization)
        credentialError = nil
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
        credentialError = nil
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
