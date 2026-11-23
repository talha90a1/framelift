// SPDX-License-Identifier: AGPL-3.0-only
// SwiftUI app: console list window, Settings (Cmd+,), stream commands.
import AppKit
import SwiftUI

final class FrameliftAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also needed when the bare SwiftPM binary is run outside an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        MainActor.assumeIsolated { AppModel.shared.appDidLaunch() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.appShouldTerminate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.appWillTerminate() }
    }
}

@main
struct FrameliftApp: App {
    @NSApplicationDelegateAdaptor(FrameliftAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @AppStorage(DebugLogs.defaultsKey) private var debugLogs = true

    var body: some Scene {
        Window("Framelift", id: "main") {
            ConsoleListView()
                .environmentObject(model)
                .environmentObject(model.consoles)
                .environmentObject(model.coordinator)
                .environmentObject(model.input)
        }
        .defaultSize(width: 620, height: 460)
        .commands {
            CommandMenu("Stream") {
                Button("Leave Stream") { model.coordinator.stop() }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                    .disabled(!model.coordinator.isActive)
                Toggle("Show Overlay", isOn: $model.settings.showOverlay)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Latency Probe (Press Options)") {
                    model.coordinator.streamWindowToggledLatencyProbe()
                    model.settings.showOverlay = true // the probe reports in the overlay
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.coordinator.isActive || !model.coordinator.debugLogs)
                Divider()
                Button("Discover Consoles") { Task { await model.discover() } }
                    .keyboardShortcut("r")
                    .disabled(model.isDiscovering)
                Divider()
                Button("Reveal Logs") { model.revealLogs() }
                    .disabled(!debugLogs)
                Button("Export Logs…") { model.exportLogs() }
                    .disabled(!debugLogs)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
