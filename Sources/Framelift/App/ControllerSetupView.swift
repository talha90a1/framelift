// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct ControllerSetupView: View {
    let status: ControllerStatus
    let didUnpair: (PairedDualSense, [PairedDualSense]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pairing = DualSensePairing()
    @State private var showGuide: Bool?
    @State private var showDevices = false
    @State private var repairingCandidate: DualSensePairing.Candidate?
    @State private var confirmRepair = false

    private var guideVisible: Bool {
        status.connected == nil && (showGuide ?? (status.lastConnected == nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(status.connected == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                details
                Spacer(minLength: 8)
                Button("Manage…") { showDevices = true }
                    .accessibilityLabel("Manage Bluetooth controllers")
                    .disabled(pairingInProgress)
                if guideVisible {
                    Button("Not Now") {
                        pairing.cancel()
                        showGuide = false
                    }
                } else if status.connected == nil {
                    Button("Pair DualSense…") { showGuide = true }
                }
            }
            if guideVisible {
                Divider()
                guide.transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: guideVisible)
        .onChange(of: status.connected) { _, controller in
            guard controller != nil else { return }
            pairing.cancel(connected: true)
            showGuide = false
        }
        .onDisappear { pairing.cancel(connected: status.connected != nil) }
        .alert("Pair this controller again?", isPresented: $confirmRepair, presenting: repairingCandidate) { candidate in
            Button("Pair Again", role: .destructive) { pairing.pairAgain(candidate) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes only this controller’s saved Bluetooth pairing from this Mac. Keep the controller unplugged and flashing in pairing mode while it pairs again.")
        }
        .sheet(isPresented: $showDevices) {
            DualSenseDevicesView(openBluetoothSettings: openBluetoothSettings, didUnpair: didUnpair)
        }
    }

    private var pairingInProgress: Bool {
        switch pairing.state {
        case .searching, .repairing, .pairing, .connecting: true
        default: false
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let controller = status.connected {
                Text(controller.name).font(.headline).lineLimit(1).help(controller.name)
                Label(status.connectionDetail ?? "Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !guideVisible, let controller = status.lastConnected {
                Text(controller.name).font(.headline).lineLimit(1).help(controller.name)
                Text(controller.kind.reconnectHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pair a DualSense").font(.headline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var guide: some View {
        HStack(alignment: .center, spacing: 16) {
            DualSensePairingDemo().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("With the controller off and unplugged, hold **Create** and **PS** until the light flashes.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                pairingActions
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var pairingActions: some View {
        switch pairing.state {
        case .idle:
            Button("Find DualSense", action: pairing.search)
                .buttonStyle(.borderedProminent)
            note("You can also use a USB data cable.")
        case .searching:
            progress("Searching for DualSense…")
        case .found(let devices):
            ForEach(devices) { candidate in
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.name).font(.callout).lineLimit(1).help(candidate.name)
                    Button(candidate.isPaired ? "Reconnect" : "Pair") { pairing.pair(candidate) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(candidate.isPaired ? "Reconnect \(candidate.name)" : "Pair \(candidate.name)")
                }
            }
            Button("Search Again", action: pairing.search)
        case .repairing:
            progress("Removing the old Mac pairing…")
        case .pairing:
            progress("Pairing…")
        case .connecting:
            progress("Connecting…")
        case .needsRepair(let candidate, let message):
            note(LocalizedStringKey(message))
            note("Turn the controller off or choose its Mac slot first. Pair Again resets this Mac’s saved pairing.")
            HStack {
                Button("Reconnect") { pairing.pair(candidate) }
                Button("Pair Again…") { askToRepair(candidate) }
            }
            Link("Switching between devices", destination: URL(string: "https://www.playstation.com/en-au/support/hardware/pair-dualsense-controller-bluetooth/")!)
                .font(.caption)
            Button("Bluetooth Settings…", action: openBluetoothSettings)
        case .failed(let message):
            note(LocalizedStringKey(message))
            Button("Try Again", action: pairing.search)
            Button("Bluetooth Settings…", action: openBluetoothSettings)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progress(_ message: LocalizedStringKey) -> some View {
        HStack {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            note(message)
            Button("Cancel") { pairing.cancel() }
        }
    }

    private func askToRepair(_ candidate: DualSensePairing.Candidate) {
        repairingCandidate = candidate
        confirmRepair = true
    }

    private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension ControllerIdentity.Kind {
    var reconnectHint: LocalizedStringKey {
        switch self {
        case .dualSense, .dualShock: "Last connected · Press PS to reconnect"
        case .xbox: "Last connected · Press Xbox to reconnect"
        case .other: "Last connected · Turn it on to reconnect"
        }
    }
}
