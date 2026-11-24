// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A fresh defaults suite for one test. A full path as the suite name makes cfprefsd keep the plist in the
/// temporary folder instead of ~/Library/Preferences, so test runs don't pile up files there.
func testDefaultsSuite() -> String {
    FileManager.default.temporaryDirectory.appending(path: "framelift-tests/\(UUID().uuidString)").path
}

/// Clears a test's defaults suite and deletes its plist.
func removeTestDefaults(_ suite: String) {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: suite + ".plist")
}
