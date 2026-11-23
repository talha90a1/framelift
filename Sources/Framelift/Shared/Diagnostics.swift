// SPDX-License-Identifier: AGPL-3.0-only
// Per-frame pipeline tracing to ~/Library/Logs/Framelift/<session>/ (frames.csv, events.log) and os_signpost.
// Only with "Debug logs" on; otherwise every call returns after one bool check. Writes are batched every 500 ms.
import Foundation
import os

/// The "Debug logs" setting (Settings > Debug). Off by default; read when a stream starts.
enum DebugLogs {
    static let defaultsKey = "framelift.debugLogs.v1"

    static func stored(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    enum Stage: Int, CaseIterable {
        case arrival, decoded, interpStart, interpEnd, midPresented, realPresented, inputSent
    }

    struct FrameRecord {
        var sequence: UInt64 = 0
        var stamps = [UInt64](repeating: 0, count: Stage.allCases.count)
        var backend: UInt8 = 0     // 0 none, 3 blend, 4 repeat, 6 Apple ML
        var discontinuity = false
        var complete: Bool { stamps[Stage.realPresented.rawValue] != 0 }
    }

    static let signposter = OSSignposter(subsystem: "com.framelift.mac", category: "Pipeline")
    static let log = Logger(subsystem: "com.framelift.mac", category: "Pipeline")

    private let lock = NSLock()
    private var open: [UInt64: FrameRecord] = [:]
    private var finished: [FrameRecord] = []
    /// Recently finished sequences: later marks for them must not open a second row.
    private var recentlyFinished: [UInt64] = []
    private var pendingEvents: [String] = []
    private let io = DispatchQueue(label: "framelift.diagnostics.io", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var framesHandle: FileHandle?
    private var eventsHandle: FileHandle?
    private(set) var directory: URL?
    private var sessionStart: UInt64 = 0
    /// Set by StreamCoordinator from the "Debug logs" setting when a stream starts.
    var enabled = false

    // MARK: lifecycle

    /// `header` (the system report) goes at the top of events.log, before the timestamped lines.
    func beginSession(label: String, header: String = "") {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = LogFolders.root.appendingPathComponent("\(stamp)-\(label)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frames = dir.appendingPathComponent("frames.csv"), events = dir.appendingPathComponent("events.log")
        FileManager.default.createFile(atPath: frames.path, contents: Data(
            "seq,arrival_ms,decode_ms,interp_wait_ms,interp_ms,arrival_to_mid_present_ms,arrival_to_real_present_ms,backend,discontinuity\n".utf8))
        FileManager.default.createFile(atPath: events.path, contents: header.isEmpty ? nil : Data((header + "\n").utf8))
        lock.lock()
        directory = dir; sessionStart = HostClock.now(); open = [:]; finished = []; recentlyFinished = []; pendingEvents = []
        framesHandle = try? FileHandle(forWritingTo: frames); framesHandle?.seekToEndOfFile()
        eventsHandle = try? FileHandle(forWritingTo: events); eventsHandle?.seekToEndOfFile()
        lock.unlock()
        let t = DispatchSource.makeTimerSource(queue: io)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume(); timer = t
        io.async { LogFolders.prune() }
        event("session start \(label) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func endSession() {
        timer?.cancel(); timer = nil
        io.sync { flush(final: true) }
        lock.lock(); try? framesHandle?.close(); try? eventsHandle?.close(); framesHandle = nil; eventsHandle = nil; lock.unlock()
    }

    // MARK: marks (any thread)

    func mark(_ stage: Stage, sequence: UInt64, at time: UInt64 = HostClock.now()) {
        guard enabled else { return }
        lock.lock()
        if open[sequence] == nil, recentlyFinished.contains(sequence) { lock.unlock(); return }
        var r = open[sequence] ?? FrameRecord(sequence: sequence)
        r.stamps[stage.rawValue] = time
        open[sequence] = r
        if r.complete { finish(sequence) }
        if open.count > 64 { // frames that never reached the screen (dropped): finish oldest
            for key in open.keys.sorted().prefix(open.count - 32) { if let r = open.removeValue(forKey: key) { finished.append(r) } }
        }
        lock.unlock()
    }

    func setBackend(_ backend: UInt8, discontinuity: Bool = false, sequence: UInt64) {
        guard enabled else { return }
        lock.lock()
        if open[sequence] == nil, recentlyFinished.contains(sequence) { lock.unlock(); return }
        var r = open[sequence] ?? FrameRecord(sequence: sequence)
        r.backend = backend; r.discontinuity = r.discontinuity || discontinuity
        open[sequence] = r
        if r.complete { finish(sequence) }
        lock.unlock()
    }

    /// Moves an open record to the output (lock held).
    private func finish(_ sequence: UInt64) {
        guard let done = open.removeValue(forKey: sequence) else { return }
        finished.append(done)
        recentlyFinished.append(sequence)
        if recentlyFinished.count > 16 { recentlyFinished.removeFirst() }
    }

    /// `text` is only built when enabled.
    func event(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        let ms = HostClock.milliseconds(from: sessionStart, to: HostClock.now())
        lock.lock(); pendingEvents.append(String(format: "%10.1f ", ms) + text); lock.unlock()
        Self.log.info("\(text, privacy: .public)")
    }

    // MARK: output

    private func flush(final: Bool = false) {
        lock.lock()
        if final { finished.append(contentsOf: open.values); open = [:] } // include frames never presented
        let rows = finished; finished = []
        let events = pendingEvents; pendingEvents = []
        let start = sessionStart, fh = framesHandle, eh = eventsHandle
        lock.unlock()
        if !rows.isEmpty, let fh {
            var out = ""
            for r in rows.sorted(by: { $0.sequence < $1.sequence }) {
                func t(_ s: Stage) -> UInt64 { r.stamps[s.rawValue] }
                func d(_ a: Stage, _ b: Stage) -> String {
                    t(a) == 0 || t(b) == 0 ? "" : String(format: "%.2f", HostClock.milliseconds(from: t(a), to: t(b)))
                }
                let arrival = t(.arrival) == 0 ? "" : String(format: "%.2f", HostClock.milliseconds(from: start, to: t(.arrival)))
                out += "\(r.sequence),\(arrival),\(d(.arrival, .decoded)),\(d(.decoded, .interpStart)),\(d(.interpStart, .interpEnd)),"
                out += "\(d(.arrival, .midPresented)),\(d(.arrival, .realPresented)),\(r.backend),\(r.discontinuity ? 1 : 0)\n"
            }
            fh.write(Data(out.utf8))
        }
        let snap = Telemetry.shared.snapshot
        var lines = events
        lines.append(String(format: "%10.1f stats src=%.1f disp=%.1f gen=%.1f hz=%.1f dec=%.2f interp=%.2f/%.2f a2p=%.1f drop=%llu rep=%llu fb=%llu lost=%llu kbps=%.0f be=%@ %@",
            HostClock.milliseconds(from: start, to: HostClock.now()), snap.sourceFPS, snap.displayedFPS, snap.generatedFPS, snap.displayHz,
            snap.decodeMsP50, snap.interpolateMsP50, snap.interpolateMsP99, snap.arrivalToPresentMsP50,
            snap.droppedFrames, snap.repeatedFrames, snap.fallbackFrames, snap.packetsLost, snap.bitrateKbps, snap.interpolationBackend, GPUTiming.shared.summary))
        eh?.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
