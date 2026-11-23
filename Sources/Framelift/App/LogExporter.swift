// SPDX-License-Identifier: AGPL-3.0-only
// "Export Logs…": a redacted zip of the system report and the newest session logs for a bug report.
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
        let sessions = Array(LogFolders.sessionFolders(in: logsRoot).prefix(Self.sessionCount))
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
        let list = sessions.isEmpty
            ? "  (none: turn on Settings > Debug > Debug logs, reproduce the problem, then export again)"
            : sessions.map { "  sessions/\($0)/" }.joined(separator: "\n")
        return """
        Framelift logs for a bug report
        ===========================

        Attach this zip to a GitHub bug report. Framelift did not upload anything; this file only leaves
        your Mac if you send it.

        What's inside
          system.txt            Mac, macOS, displays, network type, controller and Framelift settings.
          sessions/<folder>/    The newest \(Self.sessionCount) streams recorded with Debug logs on:
            events.log          Event log (redacted).
            frames.csv          Per-frame timings (numbers only, copied as is).
            summary.txt         Totals computed from the two files above.

        Sessions included
        \(list)

        What was removed
          IP addresses (IPv4 and IPv6) and MAC addresses       -> <ip-N>, <ip6-N>, <mac-addr-N>
          E-mail addresses                                     -> <email-N>
          PSN online ID and account ID                         -> <psn-id>, <psn-account>
          Paired console names, addresses and IDs              -> <console-N>, <console-id-N>
          Other console and host names                         -> <console>, <host>
          This Mac's name                                      -> <mac>
          Your home folder and user name                       -> ~, <user>
          The same value gets the same token everywhere in this zip.
          Pairing keys are never read for export.

        """
    }
}
