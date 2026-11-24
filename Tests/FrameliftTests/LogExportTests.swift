// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

private let context = RedactionContext(
    homePath: "/Users/jdoe",
    userName: "jdoe",
    macNames: ["Jane's MacBook Pro", "Janes-MacBook-Pro", "Janes-MacBook-Pro.local"],
    psnOnlineID: "CoolGamer_42",
    psnAccountID: "AbCdEfGhIjK=",
    consoles: [.init(nickname: "PS5-073", host: "192.168.1.50", id: "A1B2C3D4E5F6")]
)

private func redact(_ line: String) -> String { LogRedactor(context: context).redactLine(line) }

struct RedactionTests {
    @Test func ipv4Addresses() {
        #expect(redact("connect 10.0.0.7:9295 ok") == "connect <ip-1>:9295 ok")
        #expect(redact("from 172.16.254.1, to 8.8.8.8.") == "from <ip-1>, to <ip-2>.")
    }

    @Test func sameValueSameToken() {
        let r = LogRedactor(context: context)
        #expect(r.redactLine("a 10.0.0.7") == "a <ip-1>")
        #expect(r.redactLine("b 10.0.0.8 then 10.0.0.7") == "b <ip-2> then <ip-1>")
        #expect(r.redact("x 10.0.0.8\ny 10.0.0.7") == "x <ip-2>\ny <ip-1>")
    }

    @Test func notAddresses() {
        let untouched = [
            "session start ps5 os=Version 27.0.1 (Build 27A123)",
            "chiaki 1.2.3 ready",
            "  12:34:56.789 event",
            "settings 1920x1080@30 1080p",
            "display DELL 120.00 Hz",
            "core st=2 rx=30fps 23.5Mbps lat=0.44/0.86/0.93ms cb=0.10/0.20ms",
            "lag: arrival->handoff real mean 12.3 p95 20.1 ms",
            "octets 256.1.1.1 and 1.2.3.4.5",
            "version 10.0.0.1",
            "build=10.2.3.4",
            "std::string and Foo::Bar",
            "dead:beef:cafe",
        ]
        for line in untouched { #expect(redact(line) == line) }
    }

    @Test func ipv6Addresses() {
        #expect(redact("peer fe80::1c2b:3a4d:5e6f:7a8b%en0 up") == "peer <ip6-1> up")
        #expect(redact("[2001:db8:0:0:0:0:2:1]:9295") == "[<ip6-1>]:9295")
        #expect(redact("v4 mapped ::ffff:192.0.2.1") == "v4 mapped <ip6-1>")
    }

    @Test func macAddresses() {
        #expect(redact("bssid aa:bb:cc:dd:ee:ff") == "bssid <mac-addr-1>")
        #expect(redact("hw AA-BB-CC-DD-EE-FF") == "hw <mac-addr-1>")
        #expect(redact("mixed aa:bb-cc:dd:ee:ff") == "mixed aa:bb-cc:dd:ee:ff")
    }

    @Test func emails() {
        #expect(redact("signed in as jane.doe+psn@example.co.uk") == "signed in as <email-1>")
    }

    @Test func homePathAndUser() {
        #expect(redact("open /Users/jdoe/Library/Logs/Framelift") == "open ~/Library/Logs/Framelift")
        #expect(redact("owner jdoe and JDOE") == "owner <user> and <user>")
        #expect(redact("jdoes stays") == "jdoes stays")
        #expect(redact("near /Users/jdoe2/x") == "near /Users/<user>/x")
        #expect(redact("other /Users/alice/x and /Users/Shared/y") == "other /Users/<user>/x and /Users/Shared/y")
    }

    @Test func psnIdentifiers() {
        #expect(redact("online id CoolGamer_42 ok") == "online id <psn-id> ok")
        #expect(redact("account AbCdEfGhIjK= saved") == "account <psn-account> saved")
        #expect(redact("accountID=ZZZZZZZZZZZ=") == "accountID=<psn-account>")
        #expect(redact("psn account id: Qk1Nb3BxcnM=") == "psn account id: <psn-account>")
        #expect(redact("hash Qk1Nb3BxcnM=") == "hash Qk1Nb3BxcnM=")
    }

    @Test func consoles() {
        #expect(redact("target ps5 PS5-073 host=192.168.1.50") == "target ps5 <console-1> host=<console-1>")
        #expect(redact("discovered a1b2c3d4e5f6") == "discovered <console-id-1>")
        #expect(redact("target ps5 Living Room host=10.1.1.9") == "target ps5 <console> host=<ip-1>")
        #expect(redact("wake host=ps5-den.local") == "wake host=<host>")
    }

    @Test func genericConsoleNameIsKept() {
        let generic = RedactionContext(
            homePath: "/Users/jdoe", userName: "jdoe",
            consoles: [.init(nickname: "PS5", host: "10.0.0.2", id: "001122334455")])
        let r = LogRedactor(context: generic)
        #expect(r.redactLine("The PS5 refused the connection") == "The PS5 refused the connection")
    }

    @Test func macName() {
        #expect(redact("host Janes-MacBook-Pro.local and Jane's MacBook Pro") == "host <mac> and <mac>")
    }
}

struct SessionSummaryTests {
    private let frames = """
        seq,arrival_ms,decode_ms,interp_wait_ms,interp_ms,arrival_to_mid_present_ms,arrival_to_real_present_ms,backend,discontinuity
        0,1000.00,10.0,,,,30.00,0,0
        1,1033.33,5.0,1.0,6.00,40.00,50.00,6,0
        2,1066.67,5.0,1.0,8.00,42.00,52.00,6,0
        3,1100.00,5.0,1.0,0,,54.00,3,0
        garbage line
        4,1133.33,5.0,1.0,10.00,44.00,,4,1
        """

    private let events = """
        ==== Framelift system report ====
        Thermal state: nominal
        ==== end of system report ====

               0.0 session start ps5 os=Version 27.0 (Build 27A1)
             500.0 stats src=30.0 disp=60.0 lost=99 kbps=1 be=x gpu present=1/2 therm=nominal
            1000.0 core st=2 rx=30fps 23.5Mbps pkt=10/0 lost fec=0 ok/0 fail lost=7
            1500.0 session stats connected=1 kbps=20000 target_kbps=-1 received=100 lost=3 idr=0
            2000.0 render: missed deadline seq 12: blend shown
            2100.0 render: missed deadline seq 14: nothing generated, real frame shown early
            2200.0 render: pacer phase later (missed deadlines; budget 8.0 ms)
            2500.0 core st=2 rx=30fps 41.0Mbps pkt=10/0 lost
            3000.0 session stats connected=1 kbps=20000 target_kbps=-1 received=200 lost=5 idr=0
            3500.0 session stats connected=1 kbps=20000 target_kbps=-1 received=10 lost=2 idr=0
            4000.0 stats src=30.0 therm=fair
            4100.0 input lag: press->frame 50.0 ms + arrival->glass 30.0 = 80.0 ms | median 50.0 + 30.0 = 80.0 ms (n=1)
            4200.0 input lag: press->frame 70.0 ms + arrival->glass 30.0 = 100.0 ms | median 60.0 + 30.0 = 90.0 ms (n=2)
            4300.0 input lag: press->frame 40.0 ms + arrival->glass 30.0 = 70.0 ms | median 50.0 + 30.0 = 80.0 ms (n=3)
            5000.0 lag: arrival->handoff real mean 10.0 p95 12.0 ms | arrival->glass real mean 20.0 p95 25.0, generated p50 30.0 ms
           60500.0 lag: arrival->handoff real mean 11.0 p95 13.0 ms | arrival->glass real mean 21.0 p95 26.0, generated p50 31.0 ms
        not a timestamped line lost=1000
        """

    @Test func parsesFixture() {
        let s = SessionSummary.compute(framesCSV: frames, eventsLog: events)
        #expect(s.frames == 5)
        #expect(abs(s.realFPS - 30) < 0.01)
        #expect(s.appleML == 2 && s.blend == 1 && s.repeated == 1)
        #expect(s.interpMs == .init(mean: 8, p95: 10, count: 3))
        #expect(s.arrivalToMid?.count == 3)
        #expect(s.arrivalToReal == .init(mean: 46.5, p95: 54, count: 4))
        #expect(s.missedDeadlines == 2 && s.missedDeadlineBlends == 1)
        #expect(s.packetsLost == 7)  // 5 before the reconnect + 2 after
        #expect(s.bitrateMbps == 23.5...41.0)
        #expect(s.thermalStates == ["nominal", "fair"])
        #expect(s.inputLagMedianMs == 80 && s.inputLagSamples == 3)
        #expect(s.lastLagLine?.contains("mean 11.0") == true)
        #expect(abs(s.durationSeconds - 60.5) < 0.01)
        #expect(s.text.contains("Duration: 1m 0s"))
    }

    @Test func emptyInputs() {
        let s = SessionSummary.compute(framesCSV: "", eventsLog: "")
        #expect(s.frames == 0 && s.packetsLost == nil && s.interpMs == nil)
        #expect(s.text.contains("Input lag median: n/a"))
    }
}

struct LogFoldersTests {
    @Test func deleteRemovesLogsAndPreservesRecordings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("2026-11-24T10-00-00Z-ps5")
        let logsOnly = root.appendingPathComponent("2026-11-24T10-10-00Z-ps5")
        let outside = root.appendingPathComponent("other")
        for folder in [legacy, logsOnly, outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("events.log"))
            try Data().write(to: folder.appendingPathComponent("frames.csv"))
        }
        let link = root.appendingPathComponent("2026-11-24T10-20-00Z-ps5")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        try Data().write(to: legacy.appendingPathComponent("stream.h265"))
        try Data().write(to: legacy.appendingPathComponent("stream.times.csv"))

        try LogFolders.deleteLogs(in: root)
        #expect(LogFolders.sessionsWithLogs(in: root).isEmpty)
        #expect(try Set(fm.contentsOfDirectory(atPath: legacy.path)) == ["stream.h265", "stream.times.csv"])
        #expect(!fm.fileExists(atPath: logsOnly.path))
        #expect(fm.fileExists(atPath: outside.appendingPathComponent("events.log").path))
    }

    @Test func selectsOnlyOldSessionFolders() {
        let sessions = (1...12).map { String(format: "2026-11-%02dT10-00-00Z-ps5", $0) }
        let names = sessions + ["patches", "notes.txt", "2026-11-01-ps5", "2026-11-30T10-00-00Z-"]
        let doomed = LogFolders.namesToDelete(names.shuffled(), keep: 10)
        #expect(Set(doomed) == ["2026-11-01T10-00-00Z-ps5", "2026-11-02T10-00-00Z-ps5"])
        #expect(LogFolders.namesToDelete(Array(sessions.prefix(3)), keep: 10).isEmpty)
    }

    @Test func prunesTempDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("framelift-retention-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let sessions = (1...13).map { String(format: "2026-10-%02dT08-30-00Z-ps5", $0) }
        for name in sessions + ["patches"] { try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        fm.createFile(atPath: root.appendingPathComponent("2026-09-01T08-30-00Z-file").path, contents: Data("x".utf8))
        LogFolders.prune(root: root, keep: 10)
        let left = Set(try fm.contentsOfDirectory(atPath: root.path))
        #expect(left == Set(sessions.suffix(10) + ["patches", "2026-09-01T08-30-00Z-file"]))
        #expect(LogFolders.sessionFolders(in: root).first?.lastPathComponent == sessions.last)
    }
}

struct LogExporterTests {
    private func makeExporter(root: URL) -> LogExporter {
        LogExporter(
            logsRoot: root, systemReport: "Mac at /Users/jdoe\nNetwork: Wi-Fi (en0)\n", context: context,
            date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func stagesRedactedSessions() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("framelift-export-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent("logs")
        for i in 1...6 {
            let dir = root.appendingPathComponent(String(format: "2026-11-%02dT10-00-00Z-ps5", i))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("        10.0 target ps5 PS5-073 host=192.168.1.50\n".utf8).write(to: dir.appendingPathComponent("events.log"))
            try Data("seq,arrival_ms\n0,1.00\n".utf8).write(to: dir.appendingPathComponent("frames.csv"))
        }
        let staging = try makeExporter(root: root).stage(in: work.appendingPathComponent("out"))
        let sessions = try fm.contentsOfDirectory(atPath: staging.appendingPathComponent("sessions").path)
        #expect(sessions.count == 5 && !sessions.contains("2026-11-01T10-00-00Z-ps5"))
        let session = staging.appendingPathComponent("sessions/2026-11-06T10-00-00Z-ps5")
        let events = try String(contentsOf: session.appendingPathComponent("events.log"), encoding: .utf8)
        #expect(events.contains("target ps5 <console-1> host=<console-1>") && !events.contains("192.168"))
        #expect(fm.fileExists(atPath: session.appendingPathComponent("summary.txt").path))
        #expect(try String(contentsOf: session.appendingPathComponent("frames.csv"), encoding: .utf8) == "seq,arrival_ms\n0,1.00\n")
        let system = try String(contentsOf: staging.appendingPathComponent("system.txt"), encoding: .utf8)
        #expect(system.contains("Mac at ~") && !system.contains("jdoe"))
    }

    @Test func zipWithoutSessions() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("framelift-export-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let exporter = makeExporter(root: work.appendingPathComponent("missing"))
        #expect(exporter.fileName.hasPrefix("Framelift-logs-") && exporter.fileName.hasSuffix(".zip"))
        let zip = work.appendingPathComponent(exporter.fileName)
        try exporter.export(to: zip)
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        let out = Pipe()
        list.standardOutput = out
        try list.run()
        list.waitUntilExit()
        let entries = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        let base = exporter.baseName
        #expect(entries.contains("\(base)/README.txt") && entries.contains("\(base)/system.txt"))
    }
}
