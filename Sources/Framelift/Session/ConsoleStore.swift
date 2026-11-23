// SPDX-License-Identifier: AGPL-3.0-only
// Paired consoles: the list and the PSN account id in UserDefaults, pairing keys in owner-only files under Application Support.
import Combine
import Foundation

enum PairingStoreError: LocalizedError {
    case invalidCredentials

    var errorDescription: String? { "The pairing data is incomplete." }
}

/// Use from the main thread (it publishes to SwiftUI).
final class ConsoleStore: ObservableObject {
    static let shared = ConsoleStore()

    @Published private(set) var consoles: [PairedConsole]

    private let defaults: UserDefaults
    private let listKey = "framelift.pairedConsoles"
    private let accountKey = "framelift.psnAccountID"
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
        guard let blob = Self.readKeys(id), blob.count == 40 else { return nil }
        let credentials = ConsoleCredentials(
            accountID: blob.subdata(in: 0..<8),
            registKey: blob.subdata(in: 8..<24),
            morning: blob.subdata(in: 24..<40)
        )
        credentialCache[id] = credentials
        return credentials
    }

    func save(_ console: PairedConsole, credentials: ConsoleCredentials) throws {
        guard credentials.isValid else { throw PairingStoreError.invalidCredentials }
        var console = console
        console.id = Self.normalized(console.id)
        var blob = Data(capacity: 40)
        blob.append(credentials.accountID)
        blob.append(credentials.registKey)
        blob.append(credentials.morning)
        try Self.writeKeys(blob, id: console.id)
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
        Self.deleteKeys(id)
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

    /// ~/Library/Application Support/Framelift/Consoles, readable only by this user.
    private static let keysDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Framelift/Consoles", isDirectory: true)
    }()

    private static func keysFile(_ id: String) -> URL { keysDirectory.appendingPathComponent("\(id).keys") }

    private static func readKeys(_ id: String) -> Data? { try? Data(contentsOf: keysFile(id)) }

    private static func writeKeys(_ data: Data, id: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: keysDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: keysFile(id), options: [.atomic, .completeFileProtection])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysFile(id).path)
    }

    private static func deleteKeys(_ id: String) { try? FileManager.default.removeItem(at: keysFile(id)) }
}
