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
    private static let logFiles = ["events.log", "frames.csv"]

    static func sessionName(label: String, date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(label)"
    }

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

    static func sessionsWithLogs(in root: URL = root) -> [URL] {
        sessionFolders(in: root).filter { !existingLogs(in: $0).isEmpty }
    }

    static func deleteLogs(in root: URL = root) throws {
        for folder in sessionsWithLogs(in: root) { try deleteLogs(from: folder) }
    }

    static func prune(root: URL = root, keep: Int = keepCount) {
        let sessions = sessionFolders(in: root).filter {
            !existingLogs(in: $0).isEmpty || (try? FileManager.default.contentsOfDirectory(atPath: $0.path).isEmpty) == true
        }
        for folder in sessions.dropFirst(max(keep, 0)) { try? deleteLogs(from: folder) }
    }

    private static func existingLogs(in folder: URL) -> [URL] {
        logFiles.map { folder.appendingPathComponent($0) }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func deleteLogs(from folder: URL) throws {
        let fm = FileManager.default
        for log in existingLogs(in: folder) { try fm.removeItem(at: log) }
        if try fm.contentsOfDirectory(atPath: folder.path).isEmpty { try fm.removeItem(at: folder) }
    }

    private static func directoryNames(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
