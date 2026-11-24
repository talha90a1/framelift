// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import Framelift

struct StreamRecorderTests {
    @Test func recordsWithoutDiagnosticsAndStopsCleanly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = StreamRecorder(directory: root)
        let config = unit([0, 0, 0, 1, 0x67, 1])
        let picture = unit([0, 0, 0, 1, 0x65, 2])

        recorder.append(picture)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        recorder.append(config)
        recorder.append(picture)
        recorder.finish()
        recorder.append(picture)

        #expect(try Data(contentsOf: root.appendingPathComponent("stream.h264")) == config.data + picture.data)
        let timing = try String(contentsOf: root.appendingPathComponent("stream.times.csv"), encoding: .utf8)
        #expect(timing.split(separator: "\n").count == 3)
    }

    private func unit(_ bytes: [UInt8]) -> EncodedVideoUnit {
        EncodedVideoUnit(data: Data(bytes), codec: .h264, framesLost: 0, recovered: false, arrivalHostTime: HostClock.now())
    }
}
