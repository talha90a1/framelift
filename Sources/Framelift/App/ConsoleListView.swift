// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct ConsoleListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ConsoleStore
    @EnvironmentObject private var coordinator: StreamCoordinator
    @EnvironmentObject private var input: InputManager
    @State private var pairing: PairRequest?
    @State private var removing: PairedConsole?
    @State private var internetConsole: PairedConsole?
    @State private var showCableSetup = false
    @AppStorage("framelift.hideCableTip") private var hideCableTip = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let status = input.controllerStatus {
                    Section("Controller") {
                        ControllerSetupView(status: status, didUnpair: input.didUnpairDualSense)
                    }
                }
                Section("My consoles") {
                    if store.consoles.isEmpty {
                        Text("Turn on your PS5, then click Pair Console.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.consoles) { console in
                        PairedConsoleRow(console: console, found: model.match(console), busy: isBusy) {
                            Task { await model.wake(console) }
                        } connect: {
                            Task { await model.connect(console) }
                        } internet: {
                            internetConsole = console
                        }
                        .contextMenu {
                            Button("Connect over Internet…") { internetConsole = console }
                                .disabled(isBusy)
                            if console.lastSettings != nil {
                                Button("Use Last Settings") { model.useLastSettings(console) }
                            }
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
        .sheet(item: $internetConsole) { console in
            InternetConsoleSheet(account: model.psn, console: console).environmentObject(model)
        }
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
            Text("This removes the saved pairing. You’ll need a new PIN to reconnect.")
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
            Text("Connect your PS5 by Ethernet for a steadier stream.")
                .font(.callout)
            Spacer()
            Button("Setup", action: showSetup)
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
            Text("Connect by Ethernet").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect").font(.headline)
                Text("1. Plug an Ethernet cable from the PS5 into this Mac. A MacBook needs a USB-C Ethernet adapter.")
                Text("2. On the PS5, open **Settings › Network › Settings › Set Up Internet Connection** and choose the wired connection.")
                Text("3. In Framelift, click **Discover**, then pair or connect.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Internet Sharing (optional)").font(.headline)
                Text("1. Open **System Settings › General › Sharing**.")
                Text("2. Click **ⓘ** next to **Internet Sharing**. Share your connection from **Wi-Fi** to the Ethernet adapter, click **Done**.")
                Text("3. Turn on **Internet Sharing**.")
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
    var internet: () -> Void

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
            Menu {
                Button("On This Network", action: connect)
                Button("Over Internet…", action: internet)
            } label: { Text("Connect") } primaryAction: { connect() }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .help("Connect on this network, or choose Over Internet from the menu")
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        guard let found else { return "Not detected on this network" }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 16) {
            if let message = activity {
                if coordinator.phase != .streaming { ProgressView().controlSize(.small) }
                Text(message)
            } else {
                Label(model.targetDisplayLabel, systemImage: "display")
                Label(presetText, systemImage: "film")
            }
            Spacer()
            switch coordinator.phase {
            case .connecting:
                Button("Cancel") { coordinator.stop() }
            case .streaming:
                Button(coordinator.isRecording ? "Stop Recording" : "Record") { coordinator.toggleRecording() }
                Button("Leave Stream") { coordinator.stop() }
            case .idle, .stopping:
                EmptyView()
            }
        }
        if let message = coordinator.recordingMessage {
            Text(message).font(.caption).textSelection(.enabled)
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
        StreamPreset(settings: model.settings)?.title ?? "\(model.settings.height)p"
    }
}
