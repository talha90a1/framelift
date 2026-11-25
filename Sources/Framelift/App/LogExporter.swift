// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct LogExporter {
    static let sessionCount = 5

    var logsRoot: URL = LogFolders.root
    var systemReport: String
    var context: RedactionContext
    var date = Date()

    enum ExportError: LocalizedError {
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .zipFailed(let detail): "Couldn't create the zip file. \(detail)"
            }
        }
    }

    var baseName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "Framelift-logs-\(f.string(from: date))"
    }

    var fileName: String { baseName + ".zip" }

    /// Writes the zip to `destination`, replacing any file there.
    func export(to destination: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("framelift-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let staging = try stage(in: work)
        let zip = work.appendingPathComponent(fileName)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, zip.path]
        let errors = Pipe()
        ditto.standardError = errors
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExportError.zipFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: zip, to: destination)
    }

    /// Builds `<parent>/Framelift-logs-<stamp>/` with README.txt, system.txt and sessions/<folder>/....
    func stage(in parent: URL) throws -> URL {
        let fm = FileManager.default
        let redactor = LogRedactor(context: context)
        let staging = parent.appendingPathComponent(baseName, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let sessions = Array(LogFolders.sessionsWithLogs(in: logsRoot).prefix(Self.sessionCount))
        for folder in sessions {
            let out = staging.appendingPathComponent("sessions/\(folder.lastPathComponent)", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let frames = Self.read(folder.appendingPathComponent("frames.csv"))
            let events = Self.read(folder.appendingPathComponent("events.log"))
            if let frames { try Data(frames.utf8).write(to: out.appendingPathComponent("frames.csv")) }
            if let events { try Data(redactor.redact(events).utf8).write(to: out.appendingPathComponent("events.log")) }
            let summary = SessionSummary.compute(framesCSV: frames ?? "", eventsLog: events ?? "")
            try Data(redactor.redact(summary.text).utf8).write(to: out.appendingPathComponent("summary.txt"))
        }
        try Data(redactor.redact(systemReport).utf8).write(to: staging.appendingPathComponent("system.txt"))
        try Data(readme(sessions: sessions.map(\.lastPathComponent)).utf8).write(to: staging.appendingPathComponent("README.txt"))
        return staging
    }

    private static func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func readme(sessions: [String]) -> String {
        let list =
            sessions.isEmpty
            ? "  No sessions. Enable Debug logs and start a stream."
            : sessions.map { "  sessions/\($0)/" }.joined(separator: "\n")
        return """
            Framelift logs for a bug report
            ===========================

            Review this zip before attaching it to a bug report.

            system.txt           System and Framelift settings
            sessions/*/          Event logs, frame timings, and summaries

            Recordings, pairing keys and sign-in credentials are excluded. Names, account IDs, network addresses,
            email addresses, and home paths are replaced with placeholders.

            Sessions
            \(list)

            """
    }
}
