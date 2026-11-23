// SPDX-License-Identifier: AGPL-3.0-only
// Helpers for the fixed-size C arrays in VeyraBridge.h (imported as tuples) and for blocking bridge calls.
import Foundation
import VeyraCore

enum BridgeInterop {
    /// Process-wide chiaki init (idempotent in the core).
    static let initResult: Int32 = vr_init()

    /// Runs a blocking bridge call on a GCD worker so it never occupies the Swift cooperative pool.
    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: body()) }
        }
    }

    /// Bytes of a C array tuple.
    static func data<T>(of tuple: T) -> Data {
        withUnsafeBytes(of: tuple) { Data($0) }
    }

    /// NUL-terminated string inside a C char array tuple.
    static func string<T>(of tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Copies `data` into a C array tuple (truncating, zero-filling the rest).
    static func fill<T>(_ tuple: inout T, with data: Data) {
        withUnsafeMutableBytes(of: &tuple) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            data.prefix(raw.count).withUnsafeBytes { raw.copyMemory(from: $0) }
        }
    }

    /// Overwrites a C array tuple or struct with zeros (secrets on the stack).
    static func wipe<T>(_ value: inout T) {
        _ = withUnsafeMutableBytes(of: &value) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }

    static func credentials(_ c: ConsoleCredentials) -> VRCredentials {
        var out = VRCredentials()
        fill(&out.account_id, with: c.accountID)
        fill(&out.regist_key, with: c.registKey)
        fill(&out.morning, with: c.morning)
        return out
    }

    static func credentials(_ c: VRCredentials) -> ConsoleCredentials {
        ConsoleCredentials(accountID: data(of: c.account_id), registKey: data(of: c.regist_key), morning: data(of: c.morning))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
