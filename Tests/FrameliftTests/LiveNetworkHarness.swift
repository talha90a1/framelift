// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import FrameliftCore
@testable import Framelift

@Suite(.serialized) struct LiveNetworkHarness {
    @Test func measureConnection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["FRAMELIFT_NETWORK_REPORT"] else { return }
        let store = ConsoleStore(defaults: UserDefaults(suiteName: "com.framelift.mac")!)
        let found = await ConsoleDiscovery.discover(timeout: 2)
        let console = try #require(store.consoles.first)
        let host = found.first(where: { $0.id == console.id })?.address ?? console.host
        let credentials = try #require(store.credentials(for: console.id))
        let rates = (env["FRAMELIFT_NETWORK_BITRATES"] ?? "30000,50000,100000")
            .split(separator: ",").compactMap { UInt32($0) }
        var results: [Measurement] = []
        for (index, rate) in rates.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(22)) }
            var settings = StreamSettings()
            settings.bitrateKbps = rate
            let samples = Samples()
            let session = RemotePlaySession(host: host, credentials: credentials, settings: settings)
            session.onVideo = { unit in samples.append(unit) }
            try session.start()
            try await Task.sleep(for: .seconds(25))
            let d = session.diagnostics
            let measurement = samples.result(rate: rate, link: SystemReport.consoleLink(host: host), diagnostics: d)
            results.append(measurement)
            session.stop()
            let data = try JSONEncoder().encode(results)
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("network: \(measurement.link), cap \(rate / 1000) Mbps, \(measurement.frames) units, \(measurement.lossPercent)% lost, arrival p95 \(measurement.arrivalP95Ms) ms")
            #expect(measurement.frames > 100, "The console did not supply enough video for a network measurement")
        }
    }

    private struct Measurement: Encodable {
        var requestedKbps: UInt32
        var link: String
        var frames: Int
        var actualMbps: Double
        var arrivalP50Ms: Double
        var arrivalP95Ms: Double
        var arrivalMaxMs: Double
        var lossPercent: Double
        var fecFailed: UInt64
        var transportErrors: UInt64
    }

    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var arrivals: [UInt64] = []
        private var sizes: [Int] = []
        func append(_ unit: EncodedVideoUnit) {
            lock.withLock { arrivals.append(unit.arrivalHostTime); sizes.append(unit.data.count) }
        }
        func result(rate: UInt32, link: String, diagnostics d: VRDiagnostics) -> Measurement {
            lock.withLock {
                let times = Array(arrivals.dropFirst(60))
                let deltas = zip(times, times.dropFirst()).map { HostClock.milliseconds(from: $0, to: $1) }.sorted()
                func percentile(_ q: Double) -> Double {
                    guard !deltas.isEmpty else { return 0 }
                    return deltas[min(deltas.count - 1, Int(Double(deltas.count - 1) * q))]
                }
                let seconds = times.count > 1 ? HostClock.seconds(times.last! - times.first!) : 0
                let total = d.packets_received_total + d.packets_lost_total
                return Measurement(requestedKbps: rate, link: link, frames: times.count,
                    actualMbps: seconds > 0 ? Double(sizes.dropFirst(60).reduce(0, +)) * 8 / seconds / 1e6 : 0,
                    arrivalP50Ms: percentile(0.5), arrivalP95Ms: percentile(0.95), arrivalMaxMs: percentile(1),
                    lossPercent: total > 0 ? Double(d.packets_lost_total) * 100 / Double(total) : 0,
                    fecFailed: d.fec_failed, transportErrors: d.transport_errors)
            }
        }
    }
}
