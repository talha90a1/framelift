// SPDX-License-Identifier: AGPL-3.0-only
// Stream window: native fullscreen on the chosen display, hidden cursor, stream shortcuts, input forwarding.
import AppKit
import SwiftUI

@MainActor
protocol StreamWindowDelegate: AnyObject {
    /// Esc / Cmd+Shift+Q / window closed by the user.
    func streamWindowRequestedLeave()
    func streamWindowToggledOverlay(_ visible: Bool)
    /// Cmd+Shift+L: arm/disarm the latency probe (the user presses Options).
    func streamWindowToggledLatencyProbe()
}

/// Fullscreen windows need key status for shortcuts.
private final class StreamWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The overlay must never eat clicks meant for the stream.
@MainActor
final class StreamWindowController: NSObject, NSWindowDelegate {
    let presenterView: MetalPresenterView
    weak var delegate: StreamWindowDelegate?

    private let window: StreamWindow
    private weak var loginParent: NSWindow?
    private weak var loginPrompt: NSWindow?
    private weak var loginPromptParent: NSWindow?
    private(set) var hasShown = false
    private let wantsFullscreen: Bool
    private var overlayOn: Bool
    private var eventMonitor: Any?
    private var cursorHidden = false
    private var closingProgrammatically = false
    private var didClose = false
    private let targetScreen: NSScreen
    /// Debug logs on: the latency probe (Cmd+Shift+L) is available.
    private let debugTools: Bool

    init(settings: StreamSettings, title: String, debugTools: Bool, loginParent: NSWindow?) {
        self.loginParent = loginParent
        let screen = settings.targetDisplayID.flatMap(DisplayCatalog.screen(for:)) ?? NSScreen.main ?? NSScreen.screens[0]
        targetScreen = screen
        wantsFullscreen = settings.fullscreen
        overlayOn = settings.showOverlay
        self.debugTools = debugTools

        // 16:9 window centred on the target screen; fullscreen then expands it on that same screen.
        let visible = screen.visibleFrame
        let width = min(visible.width * 0.8, 1600)
        let size = NSSize(width: width, height: (width * 9 / 16).rounded())
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)

        // No `screen:` argument: with one, AppKit treats the rect as relative to that screen's origin and a
        // TV to the right of the laptop would get its offset applied twice. This rect is global.
        window = StreamWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        presenterView = MetalPresenterView(frame: NSRect(origin: .zero, size: size))
        super.init()

        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.tabbingMode = .disallowed
        window.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        presenterView.autoresizingMask = [.width, .height]
        presenterView.frame = container.bounds
        container.addSubview(presenterView)
        window.contentView = container

    }

    /// The screen the stream is actually on (may differ from the request if AppKit moved the window).
    var screen: NSScreen { window.screen ?? targetScreen }

    func show() {
        guard !hasShown, !closingProgrammatically else { return }
        hasShown = true
        // Fullscreen happens on whichever screen holds the window, so make sure it's the target first.
        if window.screen != targetScreen {
            let frame = window.frame
            let visible = targetScreen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        installEventMonitor()
        hideCursor()
        if wantsFullscreen, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func close() {
        guard !closingProgrammatically else { return }
        closingProgrammatically = true
        dismissLoginPrompt()
        teardownInput()
        guard window.styleMask.contains(.fullScreen) else { return finishClose() }
        // Leave fullscreen first so the Space animates away instead of leaving an empty black Space.
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.finishClose() }
    }

    private func finishClose() {
        guard !didClose else { return }
        didClose = true
        window.orderOut(nil)
        window.close()
    }

    var overlayVisible: Bool {
        get { overlayOn }
        set { overlayOn = newValue }
    }

    // MARK: Cursor (balanced hide/unhide)

    func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    // MARK: Login prompt

    /// The PSN login passcode (4 digits) the console asks for when the user has one set.
    func promptForLoginPin(completion: @escaping (String?) -> Void) {
        guard loginPrompt == nil, !closingProgrammatically else { return }
        let parent =
            hasShown
            ? window
            : (loginParent ?? NSApp.mainWindow ?? NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeKey })
        guard let parent else {
            completion(nil)
            return
        }
        showCursor()
        let alert = NSAlert()
        alert.messageText = "PS5 Login Passcode"
        alert.informativeText = "Enter your PS5 user’s four-digit passcode."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        loginPrompt = alert.window
        loginPromptParent = parent
        if !parent.isVisible { parent.makeKeyAndOrderFront(nil) }
        alert.beginSheetModal(for: parent) { [weak self] response in
            self?.loginPrompt = nil
            self?.loginPromptParent = nil
            if let self, self.hasShown, !self.closingProgrammatically { self.hideCursor() }
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func dismissLoginPrompt() {
        guard let prompt = loginPrompt, let parent = loginPromptParent else { return }
        parent.endSheet(prompt, returnCode: .cancel)
    }

    // MARK: Private

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil else { return event }
            return self.route(event)
        }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53, mods.subtracting([.function, .numericPad]).isEmpty {
            delegate?.streamWindowRequestedLeave()
            return nil
        }
        // Intercept the system Log Out shortcut while streaming.
        if key == "q", mods == [.command, .shift] {
            delegate?.streamWindowRequestedLeave()
            return nil
        }
        if key == "o", mods == [.command, .shift] {
            overlayOn.toggle()
            delegate?.streamWindowToggledOverlay(overlayOn)
            return nil
        }
        if event.keyCode == 37, mods == [.command, .shift] {  // L, swallowed without debug logs
            guard debugTools else { return nil }
            delegate?.streamWindowToggledLatencyProbe()
            if !overlayOn {
                overlayOn = true  // the probe reports in the overlay
                delegate?.streamWindowToggledOverlay(true)
            }
            return nil
        }
        return event
    }

    private func teardownInput() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        showCursor()
    }

    // MARK: NSWindowDelegate

    func windowDidExitFullScreen(_ notification: Notification) {
        if closingProgrammatically { finishClose() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !closingProgrammatically { hideCursor() }
    }

    func windowDidResignKey(_ notification: Notification) { showCursor() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard closingProgrammatically else {
            // Closing by the red button: let the coordinator stop the session, which then closes us.
            delegate?.streamWindowRequestedLeave()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { teardownInput() }
}
