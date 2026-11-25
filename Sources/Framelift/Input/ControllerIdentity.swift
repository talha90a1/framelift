// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct ControllerIdentity: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case dualSense, dualShock, xbox, other
    }

    var name: String
    var kind: Kind

    private static let defaultsKey = "framelift.lastController.v1"

    static func stored(in defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    func save(in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

struct ControllerStatus: Equatable {
    var connected: ControllerIdentity?
    var lastConnected: ControllerIdentity?
    var connectionDetail: String? = nil
}
