// SPDX-License-Identifier: AGPL-3.0-only
// Paired consoles: the list (no secrets) and the PSN account id in UserDefaults, pairing keys in the Keychain.
import Combine
import Foundation
import Security

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(text)"
        case .invalidCredentials:
            return "The pairing data is incomplete."
        }
    }
}

/// Use from the main thread (it publishes to SwiftUI).
final class ConsoleStore: ObservableObject {
    static let shared = ConsoleStore()

    @Published private(set) var consoles: [PairedConsole]

    private let defaults: UserDefaults
    private let listKey = "framelift.pairedConsoles"
    private let accountKey = "framelift.psnAccountID"
    private static let credentialService = "com.framelift.mac.console-credentials"
    /// Keychain reads can prompt, so each console's keys are read once per launch.
    private var credentialCache: [String: ConsoleCredentials] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: listKey),
           let list = try? JSONDecoder().decode([PairedConsole].self, from: data) {
            consoles = list
        } else {
            consoles = []
        }
    }

    func credentials(for consoleID: String) -> ConsoleCredentials? {
        let id = Self.normalized(consoleID)
        if let cached = credentialCache[id] { return cached }
        guard let blob = Self.readItem(service: Self.credentialService, account: id), blob.count == 40 else { return nil }
        let credentials = ConsoleCredentials(
            accountID: blob.subdata(in: 0..<8),
            registKey: blob.subdata(in: 8..<24),
            morning: blob.subdata(in: 24..<40)
        )
        credentialCache[id] = credentials
        return credentials
    }

    func save(_ console: PairedConsole, credentials: ConsoleCredentials) throws {
        guard credentials.isValid else { throw KeychainError.invalidCredentials }
        var console = console
        console.id = Self.normalized(console.id)
        var blob = Data(capacity: 40)
        blob.append(credentials.accountID)
        blob.append(credentials.registKey)
        blob.append(credentials.morning)
        try Self.writeItem(blob, service: Self.credentialService, account: console.id)
        credentialCache[console.id] = credentials
        if let index = consoles.firstIndex(where: { $0.id == console.id }) {
            consoles[index] = console
        } else {
            consoles.append(console)
        }
        persist()
    }

    func update(_ console: PairedConsole) {
        let id = Self.normalized(console.id)
        guard let index = consoles.firstIndex(where: { $0.id == id }) else { return }
        var console = console
        console.id = id
        guard consoles[index] != console else { return }
        consoles[index] = console
        persist()
    }

    func remove(_ consoleID: String) {
        let id = Self.normalized(consoleID)
        Self.deleteItem(service: Self.credentialService, account: id)
        credentialCache[id] = nil
        consoles.removeAll { $0.id == id }
        persist()
    }

    /// Remembered PSN account id (base64). Not secret, so it lives in UserDefaults.
    var psnAccountIDBase64: String? {
        get { defaults.string(forKey: accountKey) }
        set {
            objectWillChange.send()
            if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: accountKey) } else { defaults.removeObject(forKey: accountKey) }
        }
    }

    // MARK: - Private

    static func normalized(_ id: String) -> String { id.uppercased() }

    private func persist() {
        guard let data = try? JSONEncoder().encode(consoles) else { return }
        defaults.set(data, forKey: listKey)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readItem(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeItem(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { $1 }
            insert[kSecAttrLabel as String] = "Framelift"
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func deleteItem(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
