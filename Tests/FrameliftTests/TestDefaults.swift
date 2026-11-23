// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Clears a test's private defaults domain and deletes the empty plist that cfprefsd otherwise
/// leaves behind in ~/Library/Preferences, so test runs don't pile up files there.
func removeTestDefaults(_ suite: String) {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    CFPreferencesAppSynchronize(suite as CFString)
    try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(suite).plist"))
}
