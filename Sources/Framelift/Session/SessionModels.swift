// SPDX-License-Identifier: AGPL-3.0-only
// Value types shared by pairing, discovery, the console store and the remote-play session.
import Foundation

/// Registration secrets for one console. Stored in an owner-only file; never logged or printed.
struct ConsoleCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// PSN account id, 8 bytes (little endian, as chiaki expects).
    var accountID: Data
    /// Registration key, 16 bytes (ASCII hex, not necessarily NUL terminated).
    var registKey: Data
    /// Session key ("morning"), 16 bytes.
    var morning: Data

    var isValid: Bool { accountID.count == 8 && registKey.count == 16 && morning.count == 16 }

    // Redacted so string interpolation or `print` can never leak the keys.
    var description: String { "ConsoleCredentials(<redacted>)" }
    var debugDescription: String { description }
}

struct PairedConsole: Codable, Identifiable, Hashable {
    /// Console MAC as uppercase hex (same form as the discovery host id).
    var id: String
    var nickname: String
    var host: String
    var lastSettings: StreamSettings?

    // StreamSettings is only Equatable (Contracts.swift), so hash the identifying fields;
    // equality stays synthesized over all fields, which keeps hashing consistent.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(nickname)
        hasher.combine(host)
    }
}

struct DiscoveredConsole: Identifiable, Hashable {
    /// Uppercase hex host id (the console MAC); falls back to the address if the console sent none.
    var id: String
    var address: String
    var name: String
    var isPS5: Bool
    var standby: Bool
}

enum SessionEvent {
    case connected
    case loginPinRequired
    case quit(reason: Int32, message: String)
    case failed(code: Int32, message: String)
}

/// Readable text for chiaki quit reasons and bridge / Veyra / chiaki error codes.
enum SessionMessages {
    static func quitMessage(reason: Int32) -> String {
        switch reason {
        case 0: "The session ended."
        case 1: "The stream was stopped."
        case 2: "The session request didn’t complete. Check that the PS5 is on and connected to the same network."
        case 3: "The PS5 refused the connection. Check that Remote Play is enabled, or pair the console again."
        case 4: "Remote Play is already in use on another device."
        case 5: "Remote Play crashed on the PS5. Try again in a moment."
        case 6: "The PS5's Remote Play version isn't supported. Update the console."
        case 7: "The control connection to the PS5 failed."
        case 8: "Couldn't open the control connection to the PS5."
        case 9: "The PS5 refused the control connection. The pairing may no longer be valid."
        case 10: "The stream connection failed."
        case 11: "The PS5 disconnected the stream."
        case 12: "The PS5 ended the session (it may have entered rest mode or shut down)."
        case 13: "PSN registration failed. Check the account id and pair again."
        default: "The session ended (reason \(reason))."
        }
    }

    static func errorMessage(code: Int32) -> String {
        switch code {
        // Bridge (Bridge.cpp)
        case -2001: "Invalid connection settings."
        case -2002: "Internal error in the remote-play core."
        case -2003: "No active session."
        // Veyra backend / ingress
        case -1001: "The video stream couldn't be buffered."
        case -1002: "The audio stream couldn't be buffered."
        case -1003: "The PS5 sent an unsupported audio format."
        case -1004: "The PS5 sent an invalid audio frame."
        case -1100, -1101: "The stream settings or console address are invalid."
        case -1200: "Invalid pairing input. The PIN must be 8 digits and the account id 8 bytes."
        case -1201: "Pairing was canceled."
        case -1202: "The PS5 didn't answer the pairing request in time. Check the address and that the PIN screen is open."
        case -1203: "The PS5 rejected the pairing. Check the PIN and the PSN account id."
        case -1300: "Invalid console address."
        case -1301: "The stored pairing key is invalid. Pair the console again."
        case -1401: "No active network interface for discovery."
        // chiaki ChiakiErrorCode
        case 1: "Unknown error."
        case 2: "Couldn't parse the console address."
        case 3: "Couldn't start a worker thread."
        case 4: "Out of memory."
        case 6: "Network error."
        case 7: "The PS5 refused the connection."
        case 8: "The PS5 is unreachable (host down)."
        case 9: "The PS5 is unreachable."
        case 10: "The connection was closed."
        case 11: "The PS5 sent invalid data."
        case 14: "The operation was canceled."
        case 15: "The PS5 didn't respond in time."
        case 16: "The PS5 sent an invalid response."
        case 18: "The remote-play library isn't initialized."
        case 19: "Video error correction failed."
        case 20: "Remote Play version mismatch."
        case 21: "The PS5 rejected the request."
        default: "Error \(code)."
        }
    }
}
