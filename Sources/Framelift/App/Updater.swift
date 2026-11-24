// SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Sparkle
import SwiftUI

@MainActor
final class Updater: ObservableObject {
    private static let legacyDefaultsKey = "framelift.checkForUpdates.v1"

    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @Published private(set) var canCheck = false
    private var observation: AnyCancellable?

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func start() {
        let defaults = UserDefaults.standard
        if let checked = defaults.object(forKey: Self.legacyDefaultsKey) as? Bool {
            controller.updater.automaticallyChecksForUpdates = checked
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
        controller.startUpdater()
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
    }

    func checkNow() {
        controller.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkNow() }
            .disabled(!updater.canCheck)
    }
}
