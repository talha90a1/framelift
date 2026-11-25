// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: Updater
    @AppStorage(DualSenseFeedbackMode.defaultsKey) private var feedback: DualSenseFeedbackMode = .automatic
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
            model.refreshConnectionProfile()
            refreshLogAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshConnectionProfile()
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
                .help("Local or internet play is chosen from the console’s Connect menu.")
                LabeledContent("Connection", value: model.localConnectionName)
                HStack {
                    Text("\(model.activeProfile.recommendedBitrate / 1000) Mbps · HEVC").foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Recommended") { model.restoreProfileDefaults() }
                }
            }
            Section("60 fps output") {
                LabeledContent("Frame generation", value: (model.settings.codec == .hevcHDR
                    ? HDRFrameInterpolator.isSupported : AppleLLFIInterpolator.isSupported) ? "Apple ML" : "Unavailable")
                Picker("Game preset", selection: presetBinding) {
                    ForEach(Self.presets) { Text($0.title).tag($0) }
                }
                Toggle("HDR", isOn: Binding(get: { model.settings.codec == .hevcHDR },
                    set: { model.settings.codec = $0 ? .hevcHDR : .hevc }))
                    .help("Request 10-bit HDR from the PS5. HDR frame generation uses Apple ML on supported Macs.")
                LabeledContent("Maximum bitrate") {
                    HStack {
                        Slider(value: bitrateBinding, in: bitrateRange, step: 1)
                            .accessibilityLabel("Maximum bitrate in megabits per second")
                        Text("\(model.settings.bitrateKbps / 1000) Mbps").monospacedDigit().frame(width: 72, alignment: .trailing)
                    }
                }
                if model.coordinator.isActive { Text("Reconnect to apply stream changes.").settingsHelp() }
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
            Section("Clarity") {
                Toggle("Protect subtitles and HUD", isOn: $model.settings.protectSubtitles)
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
                LabeledContent("Sync", value: "Automatic")
                LabeledContent("Sound offset") {
                    HStack {
                        Slider(value: $model.settings.audioOffsetMs, in: -250...250, step: 10)
                            .accessibilityLabel("Sound offset in milliseconds")
                        Text("\(Int(model.settings.audioOffsetMs)) ms").monospacedDigit().frame(width: 62)
                    }
                }
                .help("Negative plays sound earlier; positive plays it later.")
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
            Section("Playback") {
                Picker("Display buffers", selection: $buffering) {
                    ForEach(DisplayBuffering.allCases.reversed()) { Text($0.title).tag($0) }
                }
            }
            Section("Controller") {
                Picker("Feedback", selection: $feedback) {
                    ForEach(DualSenseFeedbackMode.allCases) { Text($0.title).tag($0) }
                }
                .help("Automatic uses full effects over USB and standard feedback over Bluetooth.")
                Picker("Touchpad", selection: $touchpad) {
                    ForEach(TouchpadMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Diagnostics") {
                Toggle("Performance overlay (⇧⌘O)", isOn: $model.settings.showOverlay)
                    .help("Mac video delay excludes controller, network and PS5 processing time.")
                Toggle("Save debug logs", isOn: $debugLogs)
                HStack {
                    Button("Export Logs…") { model.exportLogs() }
                    Button("Show Logs") { model.revealLogs() }
                    Button("Delete Logs…") { confirmDeleteLogs = true }.disabled(!hasSessionLogs || model.coordinator.isActive)
                }
            }
            Section("Recordings") {
                Toggle("Save source video", isOn: $recordVideo)
                    .help("Video only, up to 5 minutes. Applies on the next stream.")
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
        return Double(limits.lowerBound) / 1000...Double(limits.upperBound) / 1000
    }

    private static let presets: [StreamPreset] = [.p1080fps30, .p1080fps60, .p720fps30, .p720fps60]

    private var presetBinding: Binding<StreamPreset> {
        Binding {
            StreamPreset(settings: model.settings) ?? .p1080fps30
        } set: { preset in
            preset.apply(to: &model.settings)
        }
    }

    private var bitrateBinding: Binding<Double> {
        Binding {
            Double(model.settings.bitrateKbps) / 1000
        } set: { value in
            model.settings.bitrateKbps = UInt32((value * 1000).rounded())
        }
    }
}

private extension Text {
    func settingsHelp() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
