// SPDX-License-Identifier: AGPL-3.0-only
// App-wide state for the UI: persisted stream settings, discovery results, displays, connect/wake flow.
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: StreamSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            profiles.save(settings, for: activeProfile)
            coordinator.applyLive(settings)
        }
    }
    @Published private(set) var discovered: [DiscoveredConsole] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var displays: [DisplayInfo] = []
    /// Wake / wait-for-boot progress shown in the console list.
    @Published private(set) var busyMessage: String?
    @Published var errorAlert: StreamCoordinator.EndAlert?
    @Published private(set) var profileSelection: ConnectionProfile
    @Published private(set) var activeProfile: ConnectionProfile = .wifi

    let consoles = ConsoleStore.shared
    let input = InputManager()
    let updates = Updater()
    let psn = PSNAccountStore()
    let coordinator: StreamCoordinator
    private let store = SettingsStore()
    private let profiles = ConnectionProfiles()
    private var screenObserver: NSObjectProtocol?
    private var coordinatorChanges: AnyCancellable?

    private init() {
        let previous = store.load()
        profiles.preservePreviousSettings(previous)
        let selection = profiles.selection
        profileSelection = selection
        let profile = selection == .automatic ? ConnectionProfile.wifi : selection
        activeProfile = profile
        settings = profiles.load(profile, preserving: previous)
        coordinator = StreamCoordinator(input: input)
        coordinator.onOverlayToggled = { [weak self] visible in self?.settings.showOverlay = visible }
        coordinator.onEnded = { [weak self] alert in
            if let alert { self?.errorAlert = alert }
        }
        // Menu commands read coordinator state through this model.
        coordinatorChanges = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
    }

    func appDidLaunch() {
        input.start()
        Task { await discover() }
        updates.start()
    }

    /// Cmd+Q while streaming: stop the session cleanly (so the PS5 sees a disconnect) before exiting.
    func appShouldTerminate() -> NSApplication.TerminateReply {
        guard coordinator.isActive else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        coordinator.stop { reply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply() }
        return .terminateLater
    }

    func appWillTerminate() {
        input.stop()
    }

    /// ~/Library/Logs/Framelift in Finder (per-stream traces from Diagnostics).
    func revealLogs() {
        let logs = LogFolders.root
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if let latest = coordinator.traceDirectory, FileManager.default.fileExists(atPath: latest.path) {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(logs)
        }
    }

    func revealRecordings() {
        let folder = VideoRecording.root
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Save panel, then a redacted zip built off the main thread; revealed in Finder when done.
    func exportLogs() {
        let exporter = LogExporter(
            systemReport: SystemReport.make(settings: settings, controller: input.controllerName, controllerFeedback: input.feedbackSummary),
            context: RedactionContext.current(consoles: consoles.consoles)
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exporter.fileName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try exporter.export(to: url) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "Couldn't export logs"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    func refreshDisplays() {
        displays = DisplayCatalog.displays()
    }

    func selectProfile(_ selection: ConnectionProfile) {
        profiles.save(settings, for: activeProfile)
        profileSelection = selection
        profiles.selection = selection
        activeProfile = selection == .automatic ? recommendedProfile : selection
        settings = profiles.load(activeProfile, preserving: settings)
    }

    var recommendedProfile: ConnectionProfile {
        guard let console = consoles.consoles.first else { return .wifi }
        let host = match(console)?.address ?? console.host
        return .detected(consoleLink: SystemReport.consoleLink(host: host))
    }

    func restoreProfileDefaults() { settings = activeProfile.defaults(preserving: settings) }

    func useLastSettings(_ console: PairedConsole) {
        guard let saved = console.lastSettings else { return }
        selectProfile(.custom)
        settings = SettingsStore.sanitized(saved)
    }

    func connectOverInternet(_ console: PairedConsole, deviceID: String) {
        guard !coordinator.isActive else { return }
        guard let credentials = consoles.credentials(for: console.id) else { return reportMissingCredentials(console) }
        guard let uid = Self.deviceID(deviceID) else {
            errorAlert = .init(title: "Choose a PS5", message: "Refresh the console list and choose your PS5 again.")
            return
        }
        var saved = console
        saved.lastSettings = settings
        saved.psnDeviceID = deviceID
        consoles.update(saved)
        if profileSelection == .automatic {
            profiles.save(settings, for: activeProfile)
            activeProfile = .internet
            settings = profiles.load(.internet, preserving: settings)
        }
        let account = psn
        coordinator.start(.console(saved, credentials), settings: effectiveSettings) {
            InternetConnection(accessToken: try await account.accessToken(for: credentials.accountID), deviceID: uid)
        }
    }

    static func deviceID(_ hex: String) -> Data? {
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Name of the display the stream will use, for the console list footer.
    var targetDisplayLabel: String {
        if let id = effectiveSettings.targetDisplayID, let display = displays.first(where: { $0.id == id }) { return display.label }
        return "Same display as this window"
    }

    // MARK: Discovery

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        discovered = await ConsoleDiscovery.discover(timeout: 2)
        adoptDiscoveredAddresses()
    }

    /// The PS5's DHCP address can change; follow it when the console's id matches a paired one.
    private func adoptDiscoveredAddresses() {
        for console in consoles.consoles {
            guard let found = match(console), found.address != console.host else { continue }
            var updated = console
            updated.host = found.address
            consoles.update(updated)
        }
    }

    func match(_ console: PairedConsole) -> DiscoveredConsole? {
        discovered.first { $0.id.caseInsensitiveCompare(console.id) == .orderedSame }
            ?? discovered.first { $0.address == console.host }
    }

    var unpairedDiscovered: [DiscoveredConsole] {
        discovered.filter { found in
            found.isPS5 && !consoles.consoles.contains { match($0)?.id == found.id }
        }
    }

    // MARK: Wake / connect

    func wake(_ console: PairedConsole) async {
        guard let credentials = consoles.credentials(for: console.id) else { return reportMissingCredentials(console) }
        busyMessage = "Waking \(console.nickname)…"
        defer { busyMessage = nil }
        if !(await ConsoleDiscovery.wake(host: console.host, credentials: credentials)) {
            errorAlert = .init(
                title: "Couldn't wake \(console.nickname)",
                message:
                    "The PS5 didn't answer at \(console.host). Check that it's in rest mode with \"Stay connected to the internet\" and \"Enable turning on PS5 from network\" on."
            )
        }
    }

    func connect(_ console: PairedConsole) async {
        guard !coordinator.isActive else { return }
        guard let credentials = consoles.credentials(for: console.id) else { return reportMissingCredentials(console) }
        if profileSelection == .automatic {
            let detected = ConnectionProfile.detected(consoleLink: SystemReport.consoleLink(host: console.host))
            if detected != activeProfile {
                profiles.save(settings, for: activeProfile)
                activeProfile = detected
                settings = profiles.load(detected, preserving: settings)
            }
        }

        // A console in rest mode has to boot before it accepts a session.
        if match(console)?.standby == true {
            busyMessage = "Waking \(console.nickname)…"
            defer { busyMessage = nil }
            _ = await ConsoleDiscovery.wake(host: console.host, credentials: credentials)
            guard await waitUntilAwake(console) else {
                errorAlert = .init(title: "\(console.nickname) didn't wake up", message: "Turn the PS5 on with the controller or power button, then try again.")
                return
            }
        }

        var remembered = console
        remembered.lastSettings = settings
        consoles.update(remembered)
        var stream = effectiveSettings
        // An HDR stream turns frame generation off, so it is asked for only when the screen can show it.
        if stream.codec == .hevcHDR, !targetScreenShowsHDR(stream.targetDisplayID) {
            stream.codec = .hevc
            Diagnostics.shared.event("settings: HDR not asked for, the screen has no HDR headroom")
        }
        coordinator.start(.console(remembered, credentials), settings: stream)
    }

    /// Settings with a stale target display (TV unplugged) mapped to "this window's display".
    var effectiveSettings: StreamSettings {
        var result = settings
        result.targetDisplayID = SettingsStore.resolvedDisplayID(settings.targetDisplayID, available: displays.map(\.id))
        return result
    }

    private func targetScreenShowsHDR(_ id: UInt32?) -> Bool {
        let screen = id.flatMap(DisplayCatalog.screen(for:)) ?? NSScreen.main ?? NSScreen.screens.first
        return (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    private func waitUntilAwake(_ console: PairedConsole) async -> Bool {
        for attempt in 1...15 {
            busyMessage = "Waiting for \(console.nickname) to start… (\(attempt * 2) s)"
            discovered = await ConsoleDiscovery.discover(timeout: 2)
            if let found = match(console), !found.standby { return true }
        }
        return false
    }

    private func reportMissingCredentials(_ console: PairedConsole) {
        errorAlert = .init(
            title: "Pairing data missing", message: "The keys for \(console.nickname) are missing on this Mac. Remove the console and pair it again.")
    }
}
