// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum VideoRecording {
    static let defaultsKey = "framelift.recordVideo.v1"

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Framelift", isDirectory: true)
    }

    static func stored(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

final class StreamRecorder: @unchecked Sendable {
    private static let maxSeconds: Double = 300
    private static let maxBytes = 1200 << 20

    private let directory: URL
    private let lock = NSLock()
    private var file: FileHandle?
    private var times: FileHandle?
    private var started: UInt64 = 0
    private var bytes = 0
    private var done = false

    init(directory: URL) {
        self.directory = directory
    }

    /// Call for every unit handed to the decoder (any thread).
    func append(_ unit: EncodedVideoUnit) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        if file == nil {
            // Start at parameter sets so the file decodes from its first byte.
            guard Self.hasParameterSets(unit) else { return }
            let url = directory.appendingPathComponent(unit.codec == .h264 ? "stream.h264" : "stream.h265")
            let tURL = directory.appendingPathComponent("stream.times.csv")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: url, options: .withoutOverwriting)
                try Data().write(to: tURL, options: .withoutOverwriting)
                file = try FileHandle(forWritingTo: url)
                times = try FileHandle(forWritingTo: tURL)
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

    func finish() {
        lock.withLock {
            done = true
            close()
        }
    }

    /// Whether the Annex-B unit carries a VPS/SPS (HEVC 32/33, H.264 7).
    private static func hasParameterSets(_ unit: EncodedVideoUnit) -> Bool {
        let b = [UInt8](unit.data)
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let h = b[i + 3]
                if unit.codec == .h264 ? (h & 0x1f) == 7 : [32, 33].contains((h >> 1) & 0x3f) { return true }
                i += 3
            } else {
                i += 1
            }
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
