// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct DualSenseDevicesView: View {
    let openBluetoothSettings: () -> Void
    let didUnpair: (PairedDualSense, [PairedDualSense]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var devices: [PairedDualSense] = []
    @State private var unpairing: PairedDualSense?
    @State private var confirmUnpair = false
    @State private var busy = false
    @State private var message: LocalizedStringKey?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paired DualSense controllers")
                .font(.headline)

            if devices.isEmpty {
                Text("No DualSense controllers are paired with this Mac.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(devices) { device in
                            deviceRow(device)
                        }
                    }
                }
                .defaultScrollAnchor(.top)
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                if showSettings {
                    Button("Bluetooth Settings…", action: openBluetoothSettings)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .padding(20)
        .frame(width: 460)
        .task {
            while !Task.isCancelled {
                if !busy {
                    let snapshot = PairedDualSense.devices()
                    if devices != snapshot { devices = snapshot }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .interactiveDismissDisabled(busy)
        .alert("Unpair controller?", isPresented: $confirmUnpair, presenting: unpairing) { device in
            Button("Unpair", role: .destructive) { perform(.unpair, on: device) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("You’ll need to pair \(displayName(device)) again to use it over Bluetooth.")
        }
    }

    private func deviceRow(_ device: PairedDualSense) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(device)).lineLimit(1)
                Text(device.isConnected ? "Connected" : "Paired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Disconnect") { perform(.disconnect, on: device) }
                .disabled(!device.isConnected)
            Button("Unpair…") {
                unpairing = device
                confirmUnpair = true
            }
        }
        .disabled(busy)
    }

    private func displayName(_ device: PairedDualSense) -> String {
        let duplicate = devices.contains { $0.id != device.id && $0.name.caseInsensitiveCompare(device.name) == .orderedSame }
        return duplicate ? "\(device.name) (\(device.id.suffix(5)))" : device.name
    }

    private func perform(_ action: PairedDualSense.Action, on device: PairedDualSense) {
        guard !busy else { return }
        busy = true
        message = nil
        showSettings = false

        Task {
            defer { busy = false }
            do {
                try await device.perform(action)
                devices = PairedDualSense.devices()
                switch action {
                case .disconnect:
                    message = "Controller disconnected."
                case .unpair:
                    message = "Controller unpaired."
                    didUnpair(device, devices)
                }
            } catch PairedDualSense.OperationError.unsupported {
                message = "In-app unpairing is unavailable on this version of macOS."
                showSettings = true
            } catch {
                devices = PairedDualSense.devices()
                switch action {
                case .disconnect: message = "Couldn’t disconnect the controller."
                case .unpair: message = "Couldn’t unpair the controller."
                }
                showSettings = true
            }
        }
    }
}
