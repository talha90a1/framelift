// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Darwin
import SwiftUI

final class FrameliftAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: model.updates)
                if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
                    let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
                {
                    Button("Show Licenses in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([license, notices])
                    }
                }
            }
            CommandMenu("Stream") {
                Toggle("Frame Generation", isOn: $model.settings.frameGeneration)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button(model.coordinator.isRecording ? "Stop Recording" : "Start Recording") { model.coordinator.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.coordinator.phase != .streaming)
                Button("Save Screenshot") { model.coordinator.saveScreenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.coordinator.phase != .streaming)
                Divider()
                Button("Leave Stream") { model.coordinator.stop() }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                    .disabled(!model.coordinator.isActive)
                Toggle("Show Performance Overlay", isOn: $model.settings.showOverlay)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Latency Probe (Press Options)") {
                    model.coordinator.streamWindowToggledLatencyProbe()
                    model.settings.showOverlay = true  // the probe reports in the overlay
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.coordinator.isActive || !model.coordinator.debugLogs)
                Divider()
                Button("Discover Consoles") { Task { await model.discover() } }
                    .keyboardShortcut("r")
                    .disabled(model.isDiscovering)
                Divider()
                Button("Show Logs in Finder") { model.revealLogs() }
                Button("Export Logs…") { model.exportLogs() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.updates)
        }
    }
}
