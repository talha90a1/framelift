// SPDX-License-Identifier: AGPL-3.0-only
// Per-session summary for exports, parsed from frames.csv and events.log. Lines it can't parse are skipped.
import Foundation

struct SessionSummary: Equatable {
    struct Stat: Equatable {
        var mean: Double
        var p95: Double
        var count: Int
    }

    var durationSeconds: Double = 0
    var frames = 0
    var realFPS: Double = 0
    /// Rows by backend: 6 Apple ML, 3 blend, 4 repeat (0, no generated frame, is not counted).
    var appleML = 0
    var blend = 0
    var repeated = 0
    var interpMs: Stat?
    var arrivalToMid: Stat?
    var arrivalToReal: Stat?
    var missedDeadlines = 0
    var missedDeadlineBlends = 0
    var packetsLost: UInt64?
    var bitrateMbps: ClosedRange<Double>?
    var thermalStates: [String] = []
    var inputLagMedianMs: Double?
    var inputLagSamples = 0
    var lastLagLine: String?

    static func compute(framesCSV: String, eventsLog: String) -> SessionSummary {
        var s = SessionSummary()
        s.parseFrames(framesCSV)
        s.parseEvents(eventsLog)
        return s
    }

    // MARK: frames.csv

    private mutating func parseFrames(_ csv: String) {
        var lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return }
        let names = ["seq", "arrival_ms", "decode_ms", "interp_wait_ms", "interp_ms",
                     "arrival_to_mid_present_ms", "arrival_to_real_present_ms", "backend", "discontinuity"]
        var column = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        if lines[0].hasPrefix("seq") {
            let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            column = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }
        var arrivals: [Double] = [], interp: [Double] = [], mid: [Double] = [], real: [Double] = []
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            func value(_ name: String) -> Double? {
                guard let i = column[name], i < fields.count, let v = Double(fields[i].trimmingCharacters(in: .whitespaces)) else { return nil }
                return v
            }
            guard value("seq") != nil else { continue }
            frames += 1
            if let a = value("arrival_ms") { arrivals.append(a) }
            if let v = value("interp_ms"), v > 0 { interp.append(v) }
            if let v = value("arrival_to_mid_present_ms"), v > 0 { mid.append(v) }
            if let v = value("arrival_to_real_present_ms"), v > 0 { real.append(v) }
            switch value("backend").map(Int.init) {
            case 6: appleML += 1
            case 3: blend += 1
            case 4: repeated += 1
            default: break
            }
        }
        if let first = arrivals.min(), let last = arrivals.max(), last > first {
            durationSeconds = (last - first) / 1000
            realFPS = Double(arrivals.count - 1) / durationSeconds
        }
        interpMs = Self.stat(interp)
        arrivalToMid = Self.stat(mid)
        arrivalToReal = Self.stat(real)
    }

    // MARK: events.log

    private static let lostField = try! NSRegularExpression(pattern: #"\blost=(\d+)"#)
    private static let mbps = try! NSRegularExpression(pattern: #"\s([\d.]+)Mbps"#)
    private static let therm = try! NSRegularExpression(pattern: #"\btherm=(\w+)"#)
    private static let inputLagTotal = try! NSRegularExpression(pattern: #"=\s*([\d.]+) ms \|"#)

    private mutating func parseEvents(_ log: String) {
        var lastTime = 0.0
        var lostTotal: UInt64 = 0, lostSegment: UInt64 = 0, sawLost = false
        var minMbps = Double.infinity, maxMbps = 0.0
        var lags: [Double] = []
        for raw in log.split(whereSeparator: \.isNewline) {
            let trimmed = raw.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let time = Double(trimmed[..<space]) else { continue }
            lastTime = max(lastTime, time)
            let message = String(trimmed[trimmed.index(after: space)...])
            if message.contains("missed deadline seq") {
                missedDeadlines += 1
                if message.hasSuffix("blend shown") { missedDeadlineBlends += 1 }
            }
            if message.hasPrefix("session stats "), let lost = Self.firstCapture(Self.lostField, in: message).flatMap(UInt64.init) {
                sawLost = true
                if lost < lostSegment { lostTotal += lostSegment } // counters restart with a new session
                lostSegment = lost
            }
            if message.hasPrefix("core "), let mb = Self.firstCapture(Self.mbps, in: message).flatMap(Double.init), mb > 0 {
                minMbps = min(minMbps, mb); maxMbps = max(maxMbps, mb)
            }
            if let state = Self.firstCapture(Self.therm, in: message), !thermalStates.contains(state) { thermalStates.append(state) }
            if message.hasPrefix("input lag:"), let total = Self.firstCapture(Self.inputLagTotal, in: message).flatMap(Double.init) {
                lags.append(total)
            }
            if message.hasPrefix("lag: ") { lastLagLine = message }
        }
        durationSeconds = max(durationSeconds, lastTime / 1000)
        if sawLost { packetsLost = lostTotal + lostSegment }
        if maxMbps > 0 { bitrateMbps = minMbps...maxMbps }
        inputLagSamples = lags.count
        if !lags.isEmpty { inputLagMedianMs = Self.percentile(lags.sorted(), 0.5) }
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: stats

    static func stat(_ values: [Double]) -> Stat? {
        guard !values.isEmpty else { return nil }
        return Stat(mean: values.reduce(0, +) / Double(values.count), p95: percentile(values.sorted(), 0.95), count: values.count)
    }

    /// Nearest-rank percentile of sorted values.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    // MARK: text

    var text: String {
        func ms(_ s: Stat?) -> String { s.map { String(format: "mean %.2f ms, p95 %.2f ms (n=%d)", $0.mean, $0.p95, $0.count) } ?? "n/a" }
        let generated = appleML + blend + repeated
        func share(_ n: Int) -> String { generated > 0 ? String(format: "%.1f%%", Double(n) * 100 / Double(generated)) : "n/a" }
        let minutes = Int(durationSeconds) / 60, seconds = Int(durationSeconds) % 60
        return [
            "Session summary (computed from frames.csv and events.log)",
            "Duration: \(minutes)m \(seconds)s",
            "Frames: \(frames) real" + (realFPS > 0 ? String(format: ", %.2f fps", realFPS) : ""),
            "Generated frames: \(generated) (Apple ML \(share(appleML)), blend \(share(blend)), repeat \(share(repeated)))",
            "interp_ms: \(ms(interpMs))",
            "arrival -> generated present: \(ms(arrivalToMid))",
            "arrival -> real present: \(ms(arrivalToReal))",
            "Missed deadlines: \(missedDeadlines) (blend shown: \(missedDeadlineBlends))",
            "Packets lost: \(packetsLost.map(String.init) ?? "n/a")",
            "Bitrate (core): " + (bitrateMbps.map { String(format: "%.1f-%.1f Mbps", $0.lowerBound, $0.upperBound) } ?? "n/a"),
            "Thermal states: \(thermalStates.isEmpty ? "n/a" : thermalStates.joined(separator: ", "))",
            "Input lag median: " + (inputLagMedianMs.map { String(format: "%.1f ms (n=%d)", $0, inputLagSamples) } ?? "n/a"),
            "Last lag line: \(lastLagLine ?? "n/a")",
        ].joined(separator: "\n") + "\n"
    }
}
