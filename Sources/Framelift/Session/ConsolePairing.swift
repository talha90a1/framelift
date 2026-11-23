// SPDX-License-Identifier: AGPL-3.0-only
// PS5 registration ("Pair Device" PIN flow) through Veyra's pairLocalPs5 (vr_pair_ps5).
import Foundation
import VeyraCore

struct PairingError: LocalizedError {
    var code: Int32
    /// What the console said (HTTP status / Sony's RP-Application-Reason), when it rejected the request.
    var consoleDetail: String = ""
    var errorDescription: String? {
        let base = SessionMessages.errorMessage(code: code)
        return consoleDetail.isEmpty ? base : "\(base) (PS5: \(consoleDetail))"
    }
}

enum ConsolePairing {
    /// - Parameters:
    ///   - host: console IPv4 address or hostname.
    ///   - accountID: 8-byte PSN account id (see `PSNAccount.decode`).
    ///   - pin: the 8-digit PIN from Settings > System > Remote Play > Pair Device.
    /// The result is not saved; call `ConsoleStore.save` with it.
    static func pair(host: String, accountID: Data, pin: String) async throws -> (PairedConsole, ConsoleCredentials) {
        let pin = pin.filter { !$0.isWhitespace }
        guard accountID.count == 8, pin.count == 8, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PairingError(code: -1200)
        }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let initResult = BridgeInterop.initResult
        guard initResult == 0 else { throw PairingError(code: initResult) }

        var result = await BridgeInterop.run { () -> VRPairResult in
            var account = [UInt8](accountID)
            defer { _ = account.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            return vr_pair_ps5(host, account, pin, 30_000)
        }
        defer { BridgeInterop.wipe(&result) }
        guard result.error == 0 else {
            let detail = BridgeInterop.string(of: result.detail)
            Diagnostics.shared.event("pairing failed code=\(result.error) console=\(detail)")
            throw PairingError(code: result.error, consoleDetail: detail)
        }

        let credentials = BridgeInterop.credentials(result.credentials)
        let mac = BridgeInterop.data(of: result.console_mac)
        let nickname = BridgeInterop.string(of: result.nickname)
        let console = PairedConsole(
            id: BridgeInterop.hex(mac),
            nickname: nickname.isEmpty ? "PS5" : nickname,
            host: host,
            lastSettings: nil
        )
        return (console, credentials)
    }
}
