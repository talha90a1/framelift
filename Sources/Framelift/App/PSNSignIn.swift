// SPDX-License-Identifier: AGPL-3.0-only
// Sony sign-in for local pairing and optional internet Remote Play.
import AppKit
import Combine
import SwiftUI
import WebKit

enum PSNSignIn {
    // Public Remote Play client credentials used by chiaki-ng and PXPlay's documented flow.
    private static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    private static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
    static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let clientDeviceID: String = {
        let key = "framelift.psnClientDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key), saved.count == 48, saved.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return saved }
        let generated = "0000000700410080" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    static let loginURL: URL = {
        var c = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        c.queryItems = [
            .init(name: "service_entity", value: "urn:service-entity:psn"),
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scope),
            .init(name: "duid", value: clientDeviceID),
            .init(name: "request_locale", value: "en_US"),
            .init(name: "ui", value: "pr"),
            .init(name: "service_logo", value: "ps"),
            .init(name: "layout_type", value: "popup"),
            .init(name: "smcid", value: "remoteplay"),
            .init(name: "prompt", value: "always"),
            .init(name: "PlatformPrivacyWs1", value: "minimal"),
        ]
        return c.url!
    }()

    enum Failure: LocalizedError {
        case noCode, http(Int), badResponse, signInRequired, differentAccount
        var errorDescription: String? {
            switch self {
            case .noCode: "Sign-in did not return a code. Try again."
            case let .http(code): "Sony's server answered with error \(code). Please try again."
            case .badResponse: "Sony's answer did not contain valid sign-in details."
            case .signInRequired: "Sign in with PlayStation in Settings › Internet Play."
            case .differentAccount: "Sign in with the same PlayStation account used to pair this PS5."
            }
        }
    }

    /// The one-time code if `url` is the Remote Play redirect, else nil.
    static func code(fromRedirect url: URL) -> String? {
        guard url.scheme == "https", url.host == "remoteplay.dl.playstation.net",
              url.path == "/remoteplay/redirect", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        return code
    }

    /// Exchanges the redirect code for the account id (Base64 of the 8-byte little-endian user id).
    struct Account {
        let accountIDBase64: String
        let onlineID: String?
        var authorization: PSNAuthorization? = nil
    }

    static func accountID(code: String) async throws -> Account {
        let auth = "Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // application/x-www-form-urlencoded with every reserved character escaped (a '+' in the code
        // would otherwise arrive as a space).
        let safe = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: safe) ?? v }
        req.httpBody = Data("grant_type=authorization_code&code=\(enc(code))&redirect_uri=\(enc(redirect))&scope=\(enc(scope))".utf8)
        req.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral)
        let (tokenData, tokenResp) = try await session.data(for: req)
        try check(tokenResp)
        guard let tokens = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
            let token = tokens["access_token"] as? String,
            let escaped = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))),
            let infoURL = URL(string: tokenURL.absoluteString + "/" + escaped)
        else { throw Failure.badResponse }

        // GET <token endpoint>/<quoted token>, built as a string so the token is escaped exactly once.
        var info = URLRequest(url: infoURL)
        info.timeoutInterval = 30
        info.setValue(auth, forHTTPHeaderField: "Authorization")
        let (infoData, infoResp) = try await session.data(for: info)
        try check(infoResp)
        let json = try JSONSerialization.jsonObject(with: infoData) as? [String: Any]
        let raw = json?["user_id"]
        guard let userID = (raw as? String).flatMap(UInt64.init) ?? (raw as? NSNumber)?.uint64Value else { throw Failure.badResponse }
        var le = userID.littleEndian
        let accountID = Data(bytes: &le, count: 8).base64EncodedString()
        let onlineID = json?["online_id"] as? String
        let authorization = try parseAuthorization(tokens, accountID: accountID, onlineID: onlineID)
        return Account(accountIDBase64: accountID, onlineID: onlineID, authorization: authorization)
    }

    static func parseAuthorization(_ json: [String: Any], accountID: String, onlineID: String?, now: Date = Date()) throws -> PSNAuthorization {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String, !refresh.isEmpty,
              let expires = json["expires_in"] as? NSNumber, expires.doubleValue.isFinite,
              expires.doubleValue > 0, expires.doubleValue < 31_536_000 else { throw Failure.badResponse }
        return PSNAuthorization(accessToken: access, refreshToken: refresh,
            expiresAt: now.addingTimeInterval(expires.doubleValue), accountIDBase64: accountID, onlineID: onlineID)
    }

    static func refresh(_ current: PSNAuthorization) async throws -> PSNAuthorization {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let safe = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        let encoded = current.refreshToken.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(encoded)".utf8)
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badResponse }
        if json["refresh_token"] == nil { json["refresh_token"] = current.refreshToken }
        return try parseAuthorization(json, accountID: current.accountIDBase64, onlineID: current.onlineID)
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
    }
}

/// Reads the address of the front tab of the user's default browser while they sign in, so the Sony
/// redirect is picked up without copy/paste. Uses Apple Events (one-time "control <browser>" consent).
/// ASWebAuthenticationSession can't be used: Sony's https redirect is on a domain this app can't claim.
@MainActor
final class BrowserSignInWatcher {
    struct Browser { let name: String; let urlScript: String; let closeScript: String }

    private static let safariLike = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromiumLike = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    /// The default browser, if it can be scripted; nil means fall back to the clipboard.
    let browser: Browser?
    let browserURL: URL?
    private var timer: Timer?
    private var denied = false
    /// Set once the front tab showed Sony's sign-in page during this attempt. A redirect tab left over
    /// from an earlier attempt (expired code) is ignored until then.
    private var sawSignInPage = false

    init() {
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        browserURL = appURL
        let id = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
        let name = appURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "your browser"
        if Self.safariLike.contains(id) {
            browser = Browser(
                name: name,
                urlScript: "tell application id \"\(id)\" to if (count of windows) > 0 then return URL of current tab of front window",
                closeScript: "tell application id \"\(id)\" to close current tab of front window")
        } else if Self.chromiumLike.contains(id) {
            browser = Browser(
                name: name,
                urlScript: "tell application id \"\(id)\" to if (count of windows) > 0 then return URL of active tab of front window",
                closeScript: "tell application id \"\(id)\" to close active tab of front window")
        } else {
            browser = nil
        }
    }

    var displayName: String {
        browser?.name ?? browserURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "your browser"
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Polls the front tab until it shows the Sony redirect; `onError` reports a missing Apple Events consent.
    func start(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        sawSignInPage = false
        guard let browser else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.denied else { return }
                var error: NSDictionary?
                let result = NSAppleScript(source: browser.urlScript)?.executeAndReturnError(&error)
                if let error, (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                    self.denied = true
                    onError("Allow Framelift to control \(browser.name) in System Settings › Privacy & Security › Automation, or copy the address (⌘L, ⌘C).")
                    return
                }
                guard let text = result?.stringValue, let url = URL(string: text) else { return }
                if url.host?.hasSuffix("sonyentertainmentnetwork.com") == true || url.host?.hasSuffix("account.sony.com") == true {
                    self.sawSignInPage = true
                    return
                }
                guard self.sawSignInPage, let code = PSNSignIn.code(fromRedirect: url) else { return }
                self.stop()
                _ = NSAppleScript(source: browser.closeScript)?.executeAndReturnError(nil)  // close the redirect tab
                NSApp.activate()
                onCode(code)
            }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

/// Sheet: sign in on Sony's page in the user's default browser (its password AutoFill works there);
/// embedded page and clipboard are fallbacks.
struct PSNSignInSheet: View {
    var onAccountID: (PSNSignIn.Account) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var failed = false
    @State private var embedded = false
    @State private var working = false
    @State private var watcher: BrowserSignInWatcher?
    @State private var authorizationTask: Task<Void, Never>?
    @State private var lastPasteboardChange = NSPasteboard.general.changeCount
    private let clipboardPoll = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text("Sign in with PlayStation").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if embedded {
                PSNWebView { code in handle(code: code) }
            } else {
                browserPanel
            }
            Divider()
            HStack {
                Spacer()
                Button(embedded ? "Use Browser" : "Sign In Here") {
                    embedded.toggle()
                    if embedded { watcher?.stop() } else { openBrowser() }
                }
                .buttonStyle(.link)
            }
            .padding(10)
        }
        .frame(width: embedded ? 560 : 480, height: embedded ? 720 : 300)
        .onAppear { openBrowser() }
        .onDisappear { watcher?.stop(); authorizationTask?.cancel() }
        .onReceive(clipboardPoll) { _ in if !embedded { checkClipboard() } }
    }

    private var browserPanel: some View {
        VStack(spacing: 14) {
            if working || !failed { ProgressView().controlSize(.large) }
            Text(status ?? "Continue in \(watcher?.displayName ?? "your browser")").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                .foregroundStyle(failed ? Color.red : Color.primary)
            Button("Reopen Sign-In Page") { openBrowser() }.disabled(working)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openBrowser() {
        let w = watcher ?? BrowserSignInWatcher()
        watcher = w
        failed = false; working = false
        status = nil
        lastPasteboardChange = NSPasteboard.general.changeCount
        w.open(PSNSignIn.loginURL)
        if w.browser == nil {
            status = "After signing in, copy the URL from the browser."
        }
        w.start(
            onCode: { handle(code: $0) },
            onError: {
                status = $0; failed = true
            })
    }

    /// Fallback for browsers without scripting, or when Automation access was declined.
    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: text), let code = PSNSignIn.code(fromRedirect: url)
        else { return }
        pb.clearContents()  // the one-time code shouldn't linger on the clipboard
        handle(code: code)
    }

    private func handle(code: String) {
        guard !working else { return }
        watcher?.stop()
        working = true; failed = false
        status = "Reading account ID…"
        authorizationTask = Task {
            do {
                let account = try await PSNSignIn.accountID(code: code)
                try Task.checkCancellation()
                onAccountID(account)
                dismiss()
            } catch {
                status = error.localizedDescription; failed = true; working = false
            }
        }
    }
}

private struct PSNWebView: NSViewRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // no cookies or tokens survive the sheet
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSNSignIn.loginURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if let url = action.request.url, let code = PSNSignIn.code(fromRedirect: url) {
                decisionHandler(.cancel)
                guard !delivered else { return }
                delivered = true
                onCode(code)
                return
            }
            decisionHandler(.allow)
        }
    }
}
