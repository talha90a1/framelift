// SPDX-License-Identifier: AGPL-3.0-only
// Main window: paired consoles (Wake / Connect), consoles found on the network, Discover, Pair.
import SwiftUI

struct ConsoleListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ConsoleStore
    @EnvironmentObject private var coordinator: StreamCoordinator
    @State private var pairing: PairRequest?
    @State private var removing: PairedConsole?
    @State private var showCableSetup = false
    @AppStorage("framelift.hideCableTip") private var hideCableTip = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("My consoles") {
                    if store.consoles.isEmpty {
                        Text("No paired PS5 yet. Turn the PS5 on, then click Pair Console.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.consoles) { console in
                        PairedConsoleRow(console: console, found: model.match(console), busy: isBusy) {
                            Task { await model.wake(console) }
                        } connect: {
                            Task { await model.connect(console) }
                        }
                        .contextMenu {
                            Button("Pair Again…") { pairing = PairRequest(host: console.host) }
                            Button("Remove…", role: .destructive) { removing = console }
                        }
                    }
                }
                if !model.unpairedDiscovered.isEmpty {
                    Section("On this network") {
                        ForEach(model.unpairedDiscovered) { found in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(found.name)
                                    Text("\(found.address) · \(found.standby ? "Rest mode" : "On")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Pair…") { pairing = PairRequest(host: found.address) }
                            }
                        }
                    }
                }
            }
            if showsCableTip {
                Divider()
                CableTip(showSetup: { showCableSetup = true }, hide: { hideCableTip = true })
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 520, minHeight: 360)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.discover() }
                } label: {
                    if model.isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Discover", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .help("Search the local network for PS5 consoles")
                .disabled(model.isDiscovering)
                Button {
                    pairing = PairRequest(host: model.unpairedDiscovered.first?.address ?? "")
                } label: {
                    Label("Pair Console", systemImage: "plus")
                }
                .help("Pair a PS5 with a PIN from Settings > System > Remote Play")
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showCableSetup) { CableSetupSheet() }
        .sheet(item: $pairing) { request in
            PairSheet(initialHost: request.host)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Remove \(removing?.nickname ?? "console")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { console in
            Button("Remove", role: .destructive) { store.remove(console.id) }
        } message: { _ in
            Text("Its Remote Play keys are deleted from the Keychain. You'll need a new PIN to pair again.")
        }
        .alert(item: $model.errorAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }

    private var isBusy: Bool { coordinator.isActive || model.busyMessage != nil }

    private var showsCableTip: Bool { !hideCableTip }
}

private struct CableTip: View {
    var showSetup: () -> Void
    var hide: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
            Text("Best experience: connect the PS5 straight to this Mac with an Ethernet cable.")
                .font(.callout)
            Spacer()
            Button("How?", action: showSetup)
            Button("Don't Show Again", action: hide)
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct CableSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    private static let sharingSettings = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Best connection: PS5 to Mac by cable").font(.title2.bold())
            Text("A direct Ethernet cable gives the lowest lag and no Wi-Fi drops.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect").font(.headline)
                Text("1. Plug an Ethernet cable from the PS5 into this Mac. A MacBook needs a USB-C Ethernet adapter.")
                Text("2. On the PS5, open **Settings › Network › Settings › Set Up Internet Connection** and choose the wired connection.")
                Text("3. In Framelift, click **Discover**, then pair or connect as usual.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Want internet on the PS5 too?").font(.headline)
                Text("Share this Mac's internet over the cable:")
                Text("1. Open **System Settings › General › Sharing**.")
                Text("2. Click **ⓘ** next to **Internet Sharing**. Share your connection from **Wi-Fi** to the Ethernet adapter, click **Done**.")
                Text("3. Turn **Internet Sharing** on. The PS5 now gets internet through your Mac.")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Open Sharing Settings") { NSWorkspace.shared.open(Self.sharingSettings) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 540)
    }
}

private struct PairRequest: Identifiable {
    let id = UUID()
    var host: String
}

private struct PairedConsoleRow: View {
    var console: PairedConsole
    var found: DiscoveredConsole?
    var busy: Bool
    var wake: () -> Void
    var connect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "playstation.logo")
                .font(.title2)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(console.nickname).font(.headline)
                Text("\(console.host) · \(statusText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Wake", action: wake)
                .disabled(busy)
                .help("Turn the PS5 on from rest mode")
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        guard let found else { return "Not found — click Discover" }
        return found.standby ? "Rest mode" : "Ready"
    }

    private var statusColor: Color {
        guard let found else { return .secondary }
        return found.standby ? .orange : .green
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: StreamCoordinator
    @EnvironmentObject private var input: InputManager

    var body: some View {
        HStack(spacing: 16) {
            if let message = activity {
                ProgressView().controlSize(.small)
                Text(message)
            } else {
                Label(input.controllerName ?? "No controller (keyboard fallback)", systemImage: "gamecontroller")
                Label(model.targetDisplayLabel, systemImage: "display")
                Label(presetText, systemImage: "film")
            }
            Spacer()
            if coordinator.isActive {
                Button("Leave Stream") { coordinator.stop() }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var activity: String? {
        if let busy = model.busyMessage { return busy }
        switch coordinator.phase {
        case .idle: return nil
        case .connecting(let text): return text
        case .streaming: return "Streaming — Esc or ⇧⌘Q to leave, ⇧⌘O for stats"
        case .stopping: return "Leaving stream…"
        }
    }

    private var presetText: String {
        let preset = StreamPreset(settings: model.settings)?.title ?? "\(model.settings.height)p"
        return "\(preset) · Apple ML 60 fps"
    }
}
