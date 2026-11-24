// SPDX-License-Identifier: AGPL-3.0-only
// While Debug logs is on, saves the decoder's Annex-B input to the session log folder (stream.h265 or
// stream.h264, from the first parameter sets) for offline tests; capped at 5 min / 1.2 GB per session.
// stream.times.csv lists each unit's arrival (ms from the first unit) and size.
import Foundation

final class StreamRecorder: @unchecked Sendable {
    static let shared = StreamRecorder()
    private static let maxSeconds: Double = 300
    private static let maxBytes = 1200 << 20

    private let lock = NSLock()
    private var file: FileHandle?
    private var times: FileHandle?
    private var started: UInt64 = 0
    private var bytes = 0
    private var done = false
    private var directory: URL?

    /// Call for every unit handed to the decoder (any thread).
    func append(_ unit: EncodedVideoUnit) {
        lock.lock(); defer { lock.unlock() }
        guard Diagnostics.shared.enabled, let dir = Diagnostics.shared.directory else { return }
        if directory != dir { close(); directory = dir; done = false }
        guard !done else { return }
        if file == nil {
            // Start at parameter sets so the file decodes from its first byte.
            guard Self.hasParameterSets(unit) else { return }
            let url = dir.appendingPathComponent(unit.codec == .hevc ? "stream.h265" : "stream.h264")
            let tURL = dir.appendingPathComponent("stream.times.csv")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            FileManager.default.createFile(atPath: tURL.path, contents: nil)
            file = try? FileHandle(forWritingTo: url)
            times = try? FileHandle(forWritingTo: tURL)
            guard file != nil, times != nil else {
                stop("couldn't open the recording files")
                return
            }
            do {
                try times?.write(contentsOf: Data("arrival_ms,bytes\n".utf8))
            } catch {
                stop(error.localizedDescription)
                return
            }
            started = unit.arrivalHostTime
            bytes = 0
            Diagnostics.shared.event("stream recording to \(url.lastPathComponent)")
        }
        guard let file else { return }
        let ms = HostClock.milliseconds(from: started, to: unit.arrivalHostTime)
        guard ms / 1000 <= Self.maxSeconds, unit.data.count <= Self.maxBytes - bytes else {
            stop(String(format: "reached the limit at %.0f s, %d MB", ms / 1000, bytes >> 20))
            return
        }
        do {
            try file.write(contentsOf: unit.data)
            try times?.write(contentsOf: Data(String(format: "%.2f,%d\n", ms, unit.data.count).utf8))
            bytes += unit.data.count
        } catch {
            stop(error.localizedDescription)
        }
    }

    /// Whether the Annex-B unit carries a VPS/SPS (HEVC 32/33, H.264 7).
    private static func hasParameterSets(_ unit: EncodedVideoUnit) -> Bool {
        let b = [UInt8](unit.data)
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let h = b[i + 3]
                if unit.codec == .hevc ? [32, 33].contains((h >> 1) & 0x3f) : (h & 0x1f) == 7 { return true }
                i += 3
            } else { i += 1 }
        }
        return false
    }

    private func close() {
        try? file?.close(); try? times?.close()
        file = nil; times = nil
    }

    private func stop(_ reason: String) {
        Diagnostics.shared.event("stream recording stopped: \(reason)")
        close()
        done = true
    }
}
