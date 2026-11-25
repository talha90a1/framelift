// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: Updater
    @AppStorage(TouchpadMode.defaultsKey) private var touchpad: TouchpadMode = .clickOnly
    @AppStorage(DebugLogs.defaultsKey) private var debugLogs = DebugLogs.enabledByDefault
    @AppStorage(VideoRecording.defaultsKey) private var recordVideo = false
    @AppStorage(DisplayBuffering.defaultsKey) private var buffering: DisplayBuffering = .triple
    @State private var hasSessionLogs = false
    @State private var confirmDeleteLogs = false
    @State private var deleteError: String?

    var body: some View {
        TabView {
            streamSettings.tabItem { Label("Stream", systemImage: "network") }
            pictureSettings.tabItem { Label("Picture", systemImage: "film") }
            soundSettings.tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            updateSettings.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            advancedSettings.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 600, height: 560)
        .onAppear {
            model.refreshDisplays()
            refreshLogAvailability()
        }
        .onChange(of: model.coordinator.phase) { refreshLogAvailability() }
        .confirmationDialog("Delete Framelift logs?", isPresented: $confirmDeleteLogs, titleVisibility: .visible) {
            Button("Delete Logs", role: .destructive) {
                guard !model.coordinator.isActive else { return }
                do { try LogFolders.deleteLogs() }
                catch { deleteError = error.localizedDescription }
                refreshLogAvailability()
            }
        } message: { Text("Your video recordings will be kept.") }
        .alert("Couldn't delete logs", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private var streamSettings: some View {
        Form {
            Section("Connection profile") {
                Picker("Profile", selection: Binding(get: { model.profileSelection }, set: { model.selectProfile($0) })) {
                    ForEach(ConnectionProfile.allCases) { Text($0.title).tag($0) }
                }
                if model.profileSelection == .automatic {
                    Text("Uses the console’s connection: \(model.activeProfile.title). Changes apply on the next connection.").settingsHelp()
                }
                Text(model.activeProfile.recommendation).settingsHelp()
                Button("Use Recommended Settings") { model.restoreProfileDefaults() }
                Text("Each profile remembers your changes.").settingsHelp()
            }
            Section("Video stream") {
                Picker("Resolution and frame rate", selection: presetBinding) {
                    ForEach(Self.presets) { Text($0.title).tag($0) }
                }
                LabeledContent("Maximum bitrate") {
                    HStack {
                        Slider(value: bitrateBinding, in: bitrateRange, step: 1000)
                            .accessibilityLabel("Maximum bitrate in megabits per second")
                        Text("\(model.settings.bitrateKbps / 1000) Mbps").monospacedDigit().frame(width: 72, alignment: .trailing)
                    }
                }
                Text("Use 30 fps for a 30 fps game; frame generation can show it at 60 fps. Stream changes apply when you reconnect.").settingsHelp()
                Toggle("HDR", isOn: hdrBinding)
                Text("HDR needs a compatible display and uses the game’s original frame rate.").settingsHelp()
            }
            Section("Internet Play") { InternetPlaySettings(account: model.psn) }
        }
        .formStyle(.grouped)
    }

    private var pictureSettings: some View {
        Form {
            Section("Display") {
                Picker("Play on", selection: $model.settings.targetDisplayID) {
                    Text("This window’s display").tag(UInt32?.none)
                    ForEach(model.displays) { Text($0.label + ($0.isBuiltIn ? " (built-in)" : "")).tag(UInt32?.some($0.id)) }
                    if let missingDisplayID { Text("Disconnected display").tag(UInt32?.some(missingDisplayID)) }
                }
                Toggle("Fullscreen", isOn: $model.settings.fullscreen)
            }
            Section("Motion and subtitles") {
                Toggle("Frame generation", isOn: $model.settings.frameGeneration)
                if model.settings.codec == .hevcHDR {
                    Text("Frame generation is unavailable with HDR.").settingsHelp()
                } else {
                    Text("Smooths 30 fps games to 60 fps. It adds processing delay; it doesn’t make the game respond faster.").settingsHelp()
                }
                Toggle("Protect subtitles", isOn: $model.settings.protectSubtitles)
                    .disabled(!model.settings.frameGeneration || model.settings.codec == .hevcHDR)
                Text("Keeps detected subtitle text sharp during camera movement.").settingsHelp()
            }
            Section("Upscaling") {
                Picker("Upscaler", selection: $model.settings.upscaler) {
                    Text("Sharp").tag(Upscaler.sharp)
                    Text("Apple MetalFX").tag(Upscaler.metalFX)
                }
                LabeledContent("Sharpness") {
                    HStack {
                        Slider(value: $model.settings.sharpness, in: StreamSettingsLimits.sharpnessRange, step: 0.05)
                            .accessibilityLabel("Sharpness")
                        Text(model.settings.sharpness, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 42)
                    }
                }
                .disabled(model.settings.upscaler == .metalFX)
            }
        }
        .formStyle(.grouped)
    }

    private var soundSettings: some View {
        Form {
            Section("Audio timing") {
                Text("Sound follows the measured video delay. The output follows your Mac’s selected audio device.").settingsHelp()
                LabeledContent("Sound offset") {
                    HStack {
                        Slider(value: $model.settings.audioOffsetMs, in: -250...250, step: 10)
                            .accessibilityLabel("Sound offset in milliseconds")
                        Text("\(Int(model.settings.audioOffsetMs)) ms").monospacedDigit().frame(width: 62)
                    }
                }
                Text("Negative plays sound earlier; positive plays it later. Bluetooth headphones may add delay that the app can’t remove.").settingsHelp()
                Button("Reset Sound Offset") { model.settings.audioOffsetMs = 0 }
            }

        }
        .formStyle(.grouped)
    }

    private var updateSettings: some View {
        Form {
            Section("App updates") {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                Toggle("Install updates automatically", isOn: $updates.automaticallyInstalls).disabled(!updates.automaticallyChecks)
                Button("Check for Updates…") { updates.checkNow() }.disabled(!updates.canCheck)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedSettings: some View {
        Form {
            Section("Frame generation") {
                Toggle("Keep interpolation ready", isOn: $model.settings.keepLLFIWarm)
                Text("Uses extra GPU work to reduce generation time. Applies when you reconnect.").settingsHelp()
                Toggle("Protect all static HUD details", isOn: $model.settings.keepStaticOverlays)
                Toggle("Blend late frames", isOn: $model.settings.blendFallback)
                Text("Both options can cause ghosting around moving objects. Leave them off unless they improve your game.").settingsHelp()
                Picker("Display buffers", selection: $buffering) {
                    ForEach(DisplayBuffering.allCases.reversed()) { Text($0.title).tag($0) }
                }
            }
            Section("Controller") {
                Picker("Touchpad", selection: $touchpad) {
                    ForEach(TouchpadMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Click only avoids accidental touches. Touch and click also sends swipes and finger positions.").settingsHelp()
            }
            Section("Diagnostics") {
                Toggle("Performance overlay (⇧⌘O)", isOn: $model.settings.showOverlay)
                Toggle("Save debug logs", isOn: $debugLogs)
                if debugLogs { Text("Measure response delay: ⇧⌘L while streaming, then press Options.").settingsHelp() }
                HStack {
                    Button("Export Logs…") { model.exportLogs() }
                    Button("Show Logs") { model.revealLogs() }
                    Button("Delete Logs…") { confirmDeleteLogs = true }.disabled(!hasSessionLogs || model.coordinator.isActive)
                }
            }
            Section("Recordings") {
                Text("While streaming, use Record or ⇧⌘R to save processed video with sound. ⇧⌘S saves a screenshot.").settingsHelp()
                Toggle("Save source video for troubleshooting", isOn: $recordVideo)
                Text("Video before processing, without sound. Saves up to 5 minutes on the next stream.").settingsHelp()
                Button("Show Recordings") { model.revealRecordings() }
            }
        }
        .formStyle(.grouped)
    }

    private func refreshLogAvailability() {
        hasSessionLogs = !LogFolders.sessionsWithLogs().isEmpty
    }

    private var missingDisplayID: UInt32? {
        guard let id = model.settings.targetDisplayID, !model.displays.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var bitrateRange: ClosedRange<Double> {
        let limits = StreamSettingsLimits.bitrateRangeKbps
        return Double(limits.lowerBound)...Double(limits.upperBound)
    }

    private static let presets: [StreamPreset] = [.p1080fps30, .p1080fps60, .p720fps30, .p720fps60]

    private var presetBinding: Binding<StreamPreset> {
        Binding {
            StreamPreset(settings: model.settings) ?? .p1080fps30
        } set: { preset in
            preset.apply(to: &model.settings)
        }
    }

    private var hdrBinding: Binding<Bool> {
        Binding {
            model.settings.codec == .hevcHDR
        } set: { on in
            model.settings.codec = on ? .hevcHDR : .hevc
        }
    }

    private var bitrateBinding: Binding<Double> {
        Binding {
            Double(model.settings.bitrateKbps)
        } set: { value in
            model.settings.bitrateKbps = UInt32(value.rounded())
        }
    }
}

private extension Text {
    func settingsHelp() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
