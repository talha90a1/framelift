// SPDX-License-Identifier: AGPL-3.0-only
// LAN discovery (directed broadcasts on every active IPv4 interface) and wake from rest mode.
import Foundation
import VeyraCore

enum ConsoleDiscovery {
    /// Blocks a GCD worker for `timeout`; returns PS5 and PS4 hosts (check `isPS5`). Empty on error.
    static func discover(timeout: TimeInterval) async -> [DiscoveredConsole] {
        guard BridgeInterop.initResult == 0 else { return [] }
        let milliseconds = UInt32(max(0.1, min(timeout, 30)) * 1000)
        return await BridgeInterop.run {
            var hosts = [VRDiscoveredHost](repeating: VRDiscoveredHost(), count: 16)
            let count = hosts.withUnsafeMutableBufferPointer {
                vr_discover($0.baseAddress, Int32($0.count), milliseconds)
            }
            guard count > 0 else { return [] }
            return hosts.prefix(Int(count)).map { host in
                let address = BridgeInterop.string(of: host.address)
                let hostID = BridgeInterop.string(of: host.host_id).uppercased()
                return DiscoveredConsole(
                    id: hostID.isEmpty ? address : hostID,
                    address: address,
                    name: BridgeInterop.string(of: host.name),
                    isPS5: host.is_ps5,
                    standby: host.standby
                )
            }
        }
    }

    /// Sends the wake-up packet (the console must allow turning on from the network). True if it was sent.
    static func wake(host: String, credentials: ConsoleCredentials) async -> Bool {
        guard BridgeInterop.initResult == 0, credentials.registKey.count == 16 else { return false }
        return await BridgeInterop.run {
            var key = [CChar](repeating: 0, count: 16)
            key.withUnsafeMutableBytes { raw in
                credentials.registKey.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            return vr_wakeup(host, key) == 0
        }
    }
}
