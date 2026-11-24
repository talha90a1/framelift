// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage(UpdateChecks.defaultsKey) private var checkForUpdates = true
    @AppStorage(TouchpadMode.defaultsKey) private var touchpad: TouchpadMode = .clickOnly
    @AppStorage(DebugLogs.defaultsKey) private var debugLogs = DebugLogs.enabledByDefault
    @AppStorage(DisplayBuffering.defaultsKey) private var buffering: DisplayBuffering = .triple
    @State private var hasSessionLogs = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Play on", selection: $model.settings.targetDisplayID) {
                    Text("Framelift window’s display").tag(UInt32?.none)
                    ForEach(model.displays) { display in
                        Text(display.label + (display.isBuiltIn ? " (built-in)" : "")).tag(UInt32?.some(display.id))
                    }
                    if let missing = missingDisplayID {
                        Text("Disconnected display").tag(UInt32?.some(missing))
                    }
                }
                Toggle("Fullscreen", isOn: $model.settings.fullscreen)
            }

            Section("Stream") {
                Picker("Resolution and frame rate", selection: presetBinding) {
                    ForEach(Self.presets) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                LabeledContent("Bitrate") {
                    HStack {
                        Slider(value: bitrateBinding, in: bitrateRange, step: 1000)
                        Text("\(model.settings.bitrateKbps / 1000) Mbps")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                Toggle("HDR", isOn: hdrBinding)
                Text("HDR requires an HDR display and turns off frame generation. Stream changes apply when you reconnect.")
                    .settingsHelp()
            }

            Section("Picture") {
                Picker("Upscaler", selection: $model.settings.upscaler) {
                    Text("Framelift").tag(Upscaler.sharp)
                    Text("Apple MetalFX").tag(Upscaler.metalFX)
                }
                LabeledContent("Sharpness") {
                    HStack {
                        Slider(value: $model.settings.sharpness, in: StreamSettingsLimits.sharpnessRange, step: 0.05)
                        Text(model.settings.sharpness, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(model.settings.upscaler == .metalFX)
            }

            Section("Frame Generation") {
                Toggle("Keep interpolation model warm", isOn: $model.settings.keepLLFIWarm)
                Text("Applies when you reconnect.").settingsHelp()
                Toggle("Keep subtitles and HUD sharp", isOn: $model.settings.keepStaticOverlays)
                Toggle("Blend when a generated frame is late", isOn: $model.settings.blendFallback)
                Picker("Display buffers", selection: $buffering) {
                    ForEach(DisplayBuffering.allCases.reversed()) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Controller") {
                Picker("Touchpad", selection: $touchpad) {
                    ForEach(TouchpadMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Updates") {
                Toggle("Check for updates at launch", isOn: $checkForUpdates)
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.status == .checking)
            }

            Section("Debug") {
                Toggle("Show performance overlay (⇧⌘O)", isOn: $model.settings.showOverlay)
                Toggle("Debug logs", isOn: $debugLogs)
                Text("Saves logs and up to five minutes of video on this Mac. Applies when you reconnect.")
                    .settingsHelp()
                if debugLogs {
                    Text("Latency probe: ⇧⌘L while streaming, then press Options.")
                        .settingsHelp()
                    HStack {
                        Button("Export Logs…") { model.exportLogs() }
                        Button("Show Logs in Finder") { model.revealLogs() }
                    }
                    Text(hasSessionLogs ? "Exports redacted logs. Video stays on this Mac." : "Start a stream to collect logs.")
                        .settingsHelp()
                }
            }

            Section {
                Button("Restore Defaults") {
                    model.settings = StreamSettings()
                    touchpad = .clickOnly
                    buffering = .triple
                    debugLogs = DebugLogs.enabledByDefault
                    checkForUpdates = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 420)
        .onAppear {
            model.refreshDisplays()
            hasSessionLogs = !LogFolders.sessionFolders().isEmpty
        }
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
