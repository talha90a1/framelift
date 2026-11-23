// SPDX-License-Identifier: AGPL-3.0-only
// Which session endings are worth one automatic reconnect. Pure, works on raw codes.
import Foundation

enum SessionRetryPolicy {
    /// chiaki `ChiakiQuitReason` values (lib/include/chiaki/session.h).
    enum QuitReason: Int32 {
        case none = 0, stopped, sessionRequestUnknown, sessionRequestConnectionRefused, remotePlayInUse,
             remotePlayCrash, versionMismatch, ctrlUnknown, ctrlConnectFailed, ctrlConnectionRefused,
             streamConnectionUnknown, streamRemoteDisconnected, streamRemoteShutdown, psnRegistFailed
    }

    /// Network-ish quits (Wi-Fi hiccup, console busy finishing a previous session) that a reconnect can fix.
    /// Not retried: user stop, console shut down / rest mode, Remote Play in use elsewhere, version or
    /// registration problems, refused connections (wrong credentials).
    static func isTransient(quitReason: Int32) -> Bool {
        switch QuitReason(rawValue: quitReason) {
        case .sessionRequestUnknown, .remotePlayCrash, .ctrlUnknown, .ctrlConnectFailed,
             .streamConnectionUnknown, .streamRemoteDisconnected:
            true
        default:
            false
        }
    }

    /// `failed(code:)` covers bridge/chiaki errors during setup or mid-stream (timeouts, socket errors), which
    /// are retried. Configuration errors (bad settings or address, invalid stored keys; codes from
    /// SessionMessages.errorMessage) can't be fixed by reconnecting.
    static func isTransient(failureCode: Int32) -> Bool {
        switch failureCode {
        case -2001, -1100, -1101, -1203 ... -1200, -1300, -1301: false
        default: true
        }
    }
}
