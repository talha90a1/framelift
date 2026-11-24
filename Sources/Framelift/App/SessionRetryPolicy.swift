// SPDX-License-Identifier: AGPL-3.0-only
// Which session endings are worth an automatic reconnect, and how long to wait. Pure, works on raw codes.
import Foundation

enum SessionRetryPolicy {
    /// Automatic reconnects in one episode before the failure is shown.
    static let maxRetries = 3

    /// Waits from PushFPS (remoteplay/PushRetryWait.h): the PS5 keeps a session's slot for about 20 s
    /// after it ends and refuses a new one until then (quit reason 4).
    enum Wait {
        /// The stream never came up, so the console holds nothing yet: 1, 2, 4 s.
        case start
        /// The console said it still holds the previous session: 10, 20, 40 s.
        case inUse
        /// A playing stream broke off and the console is still letting it go: 20, 30, 40 s.
        case afterLive
    }

    static func wait(consoleHoldsSession: Bool, wasPlaying: Bool) -> Wait {
        if consoleHoldsSession { return .inUse }
        return wasPlaying ? .afterLive : .start
    }

    /// `retry` is 1 for the first retry of an episode; clamped to 1...3.
    static func seconds(_ wait: Wait, retry: Int) -> TimeInterval {
        let n = min(max(retry, 1), 3)
        switch wait {
        case .start: return TimeInterval(1 << (n - 1))
        case .inUse: return TimeInterval(10 << (n - 1))
        case .afterLive: return TimeInterval(10 + 10 * n)
        }
    }

    static func consoleHoldsSession(quitReason: Int32) -> Bool {
        quitReason == QuitReason.remotePlayInUse.rawValue
    }

    /// chiaki `ChiakiQuitReason` values (lib/include/chiaki/session.h).
    enum QuitReason: Int32 {
        case none = 0, stopped, sessionRequestUnknown, sessionRequestConnectionRefused, remotePlayInUse,
             remotePlayCrash, versionMismatch, ctrlUnknown, ctrlConnectFailed, ctrlConnectionRefused,
             streamConnectionUnknown, streamRemoteDisconnected, streamRemoteShutdown, psnRegistFailed
    }

    /// Network-ish quits (Wi-Fi hiccup, console busy finishing a previous session) that a reconnect can fix.
    /// "In use" is retried only when the session it means is probably ours: during a reconnect, or right
    /// after a stream from this Mac ended. Otherwise another device has Remote Play.
    /// Not retried: user stop, console shut down / rest mode, version or registration problems, refused
    /// connections (wrong credentials).
    static func isTransient(quitReason: Int32, ourSessionLikely: Bool = false) -> Bool {
        switch QuitReason(rawValue: quitReason) {
        case .sessionRequestUnknown, .remotePlayCrash, .ctrlUnknown, .ctrlConnectFailed,
             .streamConnectionUnknown, .streamRemoteDisconnected:
            true
        case .remotePlayInUse:
            ourSessionLikely
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
