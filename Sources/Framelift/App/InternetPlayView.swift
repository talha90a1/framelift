// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct InternetPlaySettings: View {
    @ObservedObject var account: PSNAccountStore
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account.signedIn ? "Signed in\(account.onlineID.map { " as \($0)" } ?? "")" : "Not signed in")
            HStack {
                Button(account.signedIn ? "Sign In Again…" : "Sign in with PlayStation…") { signingIn = true }
                    .help("Pair your PS5 on the home network first.")
                if account.signedIn {
                    Button("Sign Out") {
                        do { try account.signOut() } catch { self.error = error.localizedDescription }
                    }
                }
                if account.loading { ProgressView().controlSize(.small) }
                if account.credentialError != nil {
                    Button("Try Saved Sign-in Again") { account.restoreSavedSignIn() }
                }
            }
            if let message = error ?? account.credentialError {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $signingIn) {
            PSNSignInSheet { result in
                Task {
                    do {
                        try account.accept(result)
                        try await account.refreshDevices()
                        error = nil
                    }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }
}

struct InternetConsoleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var account: PSNAccountStore
    let console: PairedConsole
    @State private var deviceID = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect over Internet").font(.title2.weight(.semibold))
            InternetPlaySettings(account: account)
            if account.signedIn {
                Picker("PS5", selection: $deviceID) {
                    Text("Choose your console").tag("")
                    ForEach(account.devices) { device in
                        Text(device.name + (device.enabled ? "" : " (Remote Play off)")).tag(device.id)
                    }
                }
                Button("Refresh Consoles") { Task { await refresh() } }
                    .disabled(account.loading)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.connectOverInternet(console, deviceID: deviceID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!account.devices.contains(where: { $0.id == deviceID && $0.enabled }) || model.coordinator.isActive)
            }
        }
        .padding(20).frame(width: 500)
        .task { if account.signedIn { await refresh() } }
        .onChange(of: account.devices) { selectSavedConsole() }
    }

    private func refresh() async {
        do { try await account.refreshDevices(); error = nil; selectSavedConsole() }
        catch { self.error = error.localizedDescription }
    }

    private func selectSavedConsole() {
        if let saved = console.psnDeviceID, account.devices.contains(where: { $0.id == saved }) { deviceID = saved }
        else if let match = account.devices.first(where: { $0.name == console.nickname }) { deviceID = match.id }
    }
}
