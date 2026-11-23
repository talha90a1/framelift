// SPDX-License-Identifier: AGPL-3.0-only
// Session log folders under ~/Library/Logs/Framelift: listing, newest-first order and retention.
import Foundation

enum LogFolders {
    static let keepCount = 10

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Framelift", isDirectory: true)
    }

    /// Names written by Diagnostics.beginSession: "<yyyy-MM-ddTHH-mm-ssZ>-<label>".
    private static let sessionPattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-[A-Za-z0-9_-]+$"#)

    static func isSessionName(_ name: String) -> Bool {
        sessionPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Session names, newest first (the UTC stamp sorts lexicographically).
    static func newestFirst(_ names: [String]) -> [String] {
        names.filter(isSessionName).sorted(by: >)
    }

    /// Session names beyond the newest `keep`; anything not named like a session is never returned.
    static func namesToDelete(_ names: [String], keep: Int = keepCount) -> [String] {
        Array(newestFirst(names).dropFirst(max(keep, 0)))
    }

    /// Session folders (directories only) in `root`, newest first.
    static func sessionFolders(in root: URL = root) -> [URL] {
        newestFirst(directoryNames(in: root)).map { root.appendingPathComponent($0, isDirectory: true) }
    }

    static func prune(root: URL = root, keep: Int = keepCount) {
        for name in namesToDelete(directoryNames(in: root), keep: keep) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static func directoryNames(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
