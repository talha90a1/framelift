// SPDX-License-Identifier: AGPL-3.0-only
// Update check, as Veyra and PushFPS do it: one anonymous request for GitHub's latest release after
// launch, nothing downloaded. A newer stable release shows a banner that opens its release page.
import AppKit
import Foundation

struct Release: Equatable {
    let version: String
    let url: URL
}

enum ReleaseCheck {
    static let repository = "talha90a1/framelift"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let maxBody = 128 * 1024

    struct Invalid: Error {}

    /// "1.2.3" or "v1.2.3" as numbers; nil for anything else (pre-release tags included).
    static func version(_ text: String) -> [Int]? {
        let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil // a part too big for Int
    }

    /// The release in a GitHub "latest release" body when it is newer than `current`, else nil.
    /// Throws for a body that isn't a published stable release of this repository.
    static func newer(than current: String, in body: Data) throws -> Release? {
        struct Body: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool
            let prerelease: Bool
        }
        let release = try JSONDecoder().decode(Body.self, from: body)
        guard !release.draft, !release.prerelease,
              let remote = version(release.tag_name), let local = version(current),
              release.html_url == "https://github.com/\(repository)/releases/tag/\(release.tag_name)",
              let url = URL(string: release.html_url)
        else { throw Invalid() }
        guard local.lexicographicallyPrecedes(remote) else { return nil }
        return Release(version: remote.map(String.init).joined(separator: "."), url: url)
    }
}

enum UpdateChecks {
    static let defaultsKey = "framelift.checkForUpdates.v1"

    static func stored(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle, checking, current, failed
        case available(Release)
    }

    @Published private(set) var status: Status = .idle
    @Published var bannerHidden = false

    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private var running: Task<Void, Never>?

    var available: Release? {
        if case .available(let release) = status { release } else { nil }
    }

    /// Once per launch, a moment after it, when the setting is on.
    func checkAfterLaunch() {
        guard UpdateChecks.stored() else { return }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if status == .idle { await check() }
        }
    }

    /// Check for Updates… and Check Now: says the result either way.
    func checkNow() {
        Task {
            await check()
            let alert = NSAlert()
            switch status {
            case .available(let release):
                alert.messageText = "Framelift \(release.version) is available"
                alert.informativeText = "You have \(currentVersion ?? "an older version"). Download it from the release page."
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
            case .current:
                alert.messageText = "Framelift is up to date"
                alert.informativeText = "\(currentVersion ?? "This version") is the latest release."
                alert.runModal()
            default:
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "GitHub didn't answer. Check your internet connection and try again."
                alert.runModal()
            }
        }
    }

    /// A check asked for while one runs waits for that one.
    private func check() async {
        if let running { return await running.value }
        let task = Task { await run() }
        running = task
        await task.value
        running = nil
    }

    private func run() async {
        guard let currentVersion else {
            status = .failed // a bare SwiftPM binary has no version
            return
        }
        status = .checking
        do {
            let body = try await Self.fetch()
            let release = try ReleaseCheck.newer(than: currentVersion, in: body)
            status = release.map { .available($0) } ?? .current
            bannerHidden = false
            Diagnostics.shared.event("update check: installed=\(currentVersion) latest=\(release?.version ?? "same or older")")
        } catch {
            status = .failed
            Diagnostics.shared.event("update check failed: \(error)")
        }
    }

    private static func fetch() async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: ReleaseCheck.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Framelift-Update-Check", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ReleaseCheck.Invalid() }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > ReleaseCheck.maxBody { throw ReleaseCheck.Invalid() }
        }
        return body
    }
}
