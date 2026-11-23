// SPDX-License-Identifier: AGPL-3.0-only
// Removes personal data from log text before export: addresses, PSN ids, console and Mac names, user name.
import Foundation
import SystemConfiguration

/// What to scrub, captured on the main thread at export time. Never holds pairing keys.
struct RedactionContext: Sendable {
    struct Console: Sendable {
        var nickname: String
        var host: String
        var id: String
    }

    var homePath: String
    var userName: String
    var macNames: [String] = []
    var psnOnlineID: String?
    var psnAccountID: String?
    var consoles: [Console] = []

    @MainActor
    static func current(consoles: [PairedConsole], defaults: UserDefaults = .standard) -> RedactionContext {
        var macNames: [String] = []
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { macNames.append(name) }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { macNames += [local, local + ".local"] }
        let host = ProcessInfo.processInfo.hostName
        macNames += [host, host.components(separatedBy: ".").first ?? host]
        return RedactionContext(
            homePath: NSHomeDirectory(),
            userName: NSUserName(),
            macNames: macNames,
            psnOnlineID: defaults.string(forKey: "framelift.psnOnlineID"),
            psnAccountID: defaults.string(forKey: "framelift.psnAccountID"),
            consoles: consoles.map { Console(nickname: $0.nickname, host: $0.host, id: $0.id) }
        )
    }
}

/// Stateful so a value gets the same numbered token (`<ip-1>`) everywhere in one export.
final class LogRedactor {
    private typealias Rule = (regex: NSRegularExpression, token: (String) -> String)

    private var literals: [Rule] = []
    private let homeRule: NSRegularExpression?
    private let userRule: NSRegularExpression?
    private var tokens: [String: [String: Int]] = [:]

    /// Names too generic to scrub without mangling ordinary log text ("The PS5 refused ...").
    private static let genericNames: Set<String> = ["ps5", "ps4", "playstation", "playstation 5", "console", "localhost", "mac", "user"]

    private static let email = regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    private static let otherUserHome = regex(#"/Users/(?!Shared\b)[^/\s]+"#)
    private static let targetLine = regex(#"(target ps\d )(.+?)( host=)"#)
    private static let hostName = regex(#"(?<=\bhost=)[A-Za-z][\w.-]*"#)
    /// A 12-character base64 value (8 bytes) after the word "account".
    private static let accountID = regex(#"(?i)(\baccount[\w ]{0,12}?[\s:="']{1,3})([A-Za-z0-9+/]{11}=)(?![A-Za-z0-9+/=])"#)
    private static let macAddress = regex(#"(?<![0-9A-Fa-f:-])[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])"#)
    private static let ipv6Candidate = regex(#"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}(?:[0-9A-Fa-f]{1,4}|\d{1,3}(?:\.\d{1,3}){3})?(?:%\w+)?(?![\w:]|\.\d)"#)
    private static let ipv4 = regex(#"(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w]|\.\d)"#)
    private static let versionContext = regex(#"(?i)\b(?:version|ver|build|macos|os|sdk|firmware|fw)[\s=:]*$"#)

    init(context: RedactionContext) {
        homeRule = context.homePath.count > 1
            ? Self.regex(NSRegularExpression.escapedPattern(for: context.homePath) + "(?![\\w.-])") : nil
        let user = context.userName
        userRule = user.count >= 3 && !Self.genericNames.contains(user.lowercased()) ? Self.wholeWord(user) : nil
        var pairs: [(String, String)] = []
        if let id = context.psnOnlineID { pairs.append((id, "<psn-id>")) }
        if let id = context.psnAccountID { pairs.append((id, "<psn-account>")) }
        for (i, console) in context.consoles.enumerated() {
            pairs += [(console.nickname, "<console-\(i + 1)>"), (console.host, "<console-\(i + 1)>"), (console.id, "<console-id-\(i + 1)>")]
        }
        pairs += context.macNames.map { ($0, "<mac>") }
        var seen = Set<String>()
        literals = pairs
            .filter { value, _ in
                let key = value.lowercased()
                return value.count >= 3 && !Self.genericNames.contains(key) && seen.insert(key).inserted
            }
            .sorted { $0.0.count > $1.0.count }
            .map { value, token in (Self.wholeWord(value), { _ in token }) }
    }

    /// Redacts each line of `text`.
    func redact(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { redactLine(String($0)) }.joined(separator: "\n")
    }

    func redactLine(_ input: String) -> String {
        var line = Self.replace(Self.email, in: input) { self.token("email", $0) }
        if let homeRule { line = Self.replace(homeRule, in: line) { _ in "~" } }
        line = Self.replace(Self.otherUserHome, in: line) { _ in "/Users/<user>" }
        for rule in literals { line = Self.replace(rule.regex, in: line, rule.token) }
        line = Self.replaceTargetLine(line)
        line = Self.replace(Self.hostName, in: line) { $0.hasPrefix("<") ? nil : "<host>" }
        line = Self.replace(Self.accountID, in: line, group: 2) { _ in "<psn-account>" }
        line = Self.replace(Self.macAddress, in: line) { self.token("mac-addr", $0.uppercased().replacingOccurrences(of: "-", with: ":")) }
        line = Self.replace(Self.ipv6Candidate, in: line) { match in
            Self.isIPv6(match) ? self.token("ip6", match.lowercased()) : nil
        }
        line = redactIPv4(line)
        if let userRule { line = Self.replace(userRule, in: line) { _ in "<user>" } }
        return line
    }

    // MARK: rules

    /// "target ps5 <nickname> host=..." names the console even when it is no longer paired.
    private static func replaceTargetLine(_ line: String) -> String {
        let ns = line as NSString
        guard let m = targetLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        let name = ns.substring(with: m.range(at: 2))
        guard !name.hasPrefix("<console") else { return line }
        return ns.replacingCharacters(in: m.range(at: 2), with: "<console>")
    }

    private func redactIPv4(_ line: String) -> String {
        let ns = line as NSString
        var edits: [(NSRange, String)] = []
        for m in Self.ipv4.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let octetsValid = (1...4).allSatisfy { i in Int(ns.substring(with: m.range(at: i))).map { $0 <= 255 } ?? false }
            guard octetsValid else { continue }
            let windowStart = max(0, m.range.location - 16)
            let before = ns.substring(with: NSRange(location: windowStart, length: m.range.location - windowStart))
            if Self.versionContext.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { continue }
            edits.append((m.range, token("ip", ns.substring(with: m.range))))
        }
        return Self.splice(edits, into: ns)
    }

    private func token(_ kind: String, _ value: String) -> String {
        var map = tokens[kind] ?? [:]
        let n = map[value] ?? map.count + 1
        map[value] = n
        tokens[kind] = map
        return "<\(kind)-\(n)>"
    }

    // MARK: helpers

    static func isIPv6(_ candidate: String) -> Bool {
        let address = candidate.split(separator: "%", maxSplits: 1).first.map(String.init) ?? candidate
        guard address.contains(where: \.isHexDigit) else { return false }
        var storage = in6_addr()
        return inet_pton(AF_INET6, address, &storage) == 1
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Case-insensitive literal match not touching other word characters.
    private static func wholeWord(_ value: String) -> NSRegularExpression {
        regex("(?i)(?<![\\w])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\w])")
    }

    /// Replaces each match with `transform(matchText)`; nil keeps the match.
    private static func replace(_ regex: NSRegularExpression, in line: String, group: Int = 0, _ transform: (String) -> String?) -> String {
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        // Transform in reading order so numbered tokens follow first appearance; splice from the end.
        let edits = matches.compactMap { m -> (NSRange, String)? in
            let range = m.range(at: group)
            return transform(ns.substring(with: range)).map { (range, $0) }
        }
        return splice(edits, into: ns)
    }

    /// Applies non-overlapping edits given in ascending order.
    private static func splice(_ edits: [(NSRange, String)], into text: NSString) -> String {
        var result = text
        for (range, replacement) in edits.reversed() {
            result = result.replacingCharacters(in: range, with: replacement) as NSString
        }
        return result as String
    }
}
