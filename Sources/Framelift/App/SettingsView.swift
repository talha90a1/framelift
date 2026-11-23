// SPDX-License-Identifier: AGPL-3.0-only
// Settings window (Cmd+,): display, fullscreen, bitrate, frame generation, touchpad, overlay, debug logs.
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(TouchpadMode.defaultsKey) private var touchpad: TouchpadMode = .clickOnly
    @AppStorage(DebugLogs.defaultsKey) private var debugLogs = true
    @AppStorage(DisplayBuffering.defaultsKey) private var buffering: DisplayBuffering = .triple
    @State private var hasSessionLogs = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Play on", selection: $model.settings.targetDisplayID) {
                    Text("Same display as the Framelift window").tag(UInt32?.none)
                    ForEach(model.displays) { display in
                        Text(display.label + (display.isBuiltIn ? " (built-in)" : "")).tag(UInt32?.some(display.id))
                    }
                    if let missing = missingDisplayID {
                        Text("Disconnected display (\(missing))").tag(UInt32?.some(missing))
                    }
                }
                Toggle("Fullscreen", isOn: $model.settings.fullscreen)
                Text("Pick your TV to stream there over HDMI. Fullscreen also lets macOS turn on Game Mode.")
                    .settingsHelp()
            }

            Section("Stream") {
                LabeledContent("Bitrate") {
                    HStack {
                        Slider(value: bitrateBinding, in: bitrateRange, step: 1000)
                        Text("\(model.settings.bitrateKbps / 1000) Mbps")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                Text("1080p, 30 fps from the PS5, shown at 60 fps with Apple's frame interpolation. 30 Mbps (default) suits most Wi-Fi. On Ethernet or a direct cable, use 50 Mbps for the sharpest picture. This is a maximum: the PS5 lowers it by itself when packets drop.")
                    .settingsHelp()
            }

            Section("Frame generation") {
                LabeledContent("Engine") {
                    Text("Apple ML interpolation · 30 → 60 fps").foregroundStyle(.secondary)
                }
                Toggle("Keep Apple ML warm (recommended)", isOn: $model.settings.keepLLFIWarm)
                Text("Runs a spare request between frames so the model stays fast; about 4–5 ms less lag per generated frame. Takes effect from the next stream.")
                    .settingsHelp()
                Toggle("Keep subtitles and HUD sharp (recommended)", isOn: $model.settings.keepStaticOverlays)
                Text("Copies text and UI that don't move from the real frames, so the model can't smear them.")
                    .settingsHelp()
                Toggle("Blend a stand-in frame when Apple ML is late (recommended)", isOn: $model.settings.blendFallback)
                Text("Shows a 50/50 mix of the two real frames instead of repeating one when a generated frame misses its slot.")
                    .settingsHelp()
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
                Text("Click only sends just the touchpad press. Some games open the map on a Remote Play touch. Use Touch + click for games that need swipes.")
                    .settingsHelp()
            }

            Section("Debug") {
                Toggle("Show performance overlay (⇧⌘O)", isOn: $model.settings.showOverlay)
                Toggle("Debug logs", isOn: $debugLogs)
                Text("Writes a log folder per stream to ~/Library/Logs/Framelift/, with a recording of the stream (up to 5 minutes) for offline tests. Takes effect from the next stream.")
                    .settingsHelp()
                if debugLogs {
                    Text("Latency probe: ⇧⌘L while streaming, then press Options.")
                        .settingsHelp()
                    HStack {
                        Button("Export Logs…") { model.exportLogs() }
                        Button("Show Logs in Finder") { model.revealLogs() }
                    }
                    Text("Logs stay on this Mac. Export makes a zip with IP addresses, PSN IDs, console names and your user name removed; attach it to a bug report.")
                        .settingsHelp()
                    if !hasSessionLogs {
                        Text("No stream logs yet: play a stream with Debug logs on and reproduce the problem first, then export.")
                            .settingsHelp()
                    }
                }
            }

            Section {
                Button("Restore Defaults") {
                    model.settings = StreamSettings()
                    touchpad = .clickOnly
                    buffering = .triple
                    debugLogs = false
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
