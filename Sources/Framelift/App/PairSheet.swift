// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct PairSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var host: String
    @State private var accountID = ""
    @State private var pin = ""
    @State private var isPairing = false
    @State private var pairingTask: Task<Void, Never>?
    @State private var error: String?
    @State private var showSignIn = false
    @State private var manualAccount = false
    @AppStorage("framelift.psnOnlineID") private var onlineID = ""

    init(initialHost: String) {
        _host = State(initialValue: initialHost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a PS5").font(.title2.bold())

            Form {
                TextField("Console IP address", text: $host, prompt: Text("192.168.1.20"))
                LabeledContent("PlayStation account") {
                    VStack(alignment: .leading, spacing: 8) {
                        if accountID.isEmpty {
                            Text("Choose the account used on your PS5").foregroundStyle(.secondary)
                        } else {
                            Label(onlineID.isEmpty ? "Account ID entered" : "Pairing as \(onlineID)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Button(accountID.isEmpty ? "Sign in with PlayStation" : "Sign In Again") { showSignIn = true }
                            if !accountID.isEmpty {
                                Button("Clear Account") { signOut() }
                            }
                            Button(manualAccount ? "Hide ID" : "Enter ID…") { manualAccount.toggle() }
                                .help("Paste an account id manually (for example from chiaki-ng's psn-account-id script)")
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if manualAccount {
                    TextField("PSN account ID", text: $accountID, prompt: Text("Base64 (ends in =) or decimal"))
                }
                TextField("PIN", text: $pin, prompt: Text("8 digits"))
                    .onChange(of: pin) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(8))
                        if digits != value { pin = digits }
                    }
            }
            .disabled(isPairing)

            VStack(alignment: .leading, spacing: 6) {
                Text("On the PS5, open **Settings › System › Remote Play › Pair Device** to get the PIN.")
                Text("Use the PlayStation account that opened **Pair Device** on the PS5.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }

            HStack {
                if isPairing { ProgressView().controlSize(.small); Text("Pairing…") }
                Spacer()
                Button("Cancel", role: .cancel) { pairingTask?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { pairingTask = Task { await pair() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPair)
            }
        }
        .padding(20)
        .frame(width: 540)
        .sheet(isPresented: $showSignIn) {
            PSNSignInSheet { account in
                accountID = account.accountIDBase64
                onlineID = account.onlineID ?? ""
                model.consoles.psnAccountIDBase64 = account.accountIDBase64
            }
        }
        .onDisappear { pairingTask?.cancel() }
        .onAppear {
            if accountID.isEmpty { accountID = model.consoles.psnAccountIDBase64 ?? "" }
        }
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canPair: Bool {
        !isPairing && !trimmedHost.isEmpty && pin.count == 8 && !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func signOut() {
        accountID = ""
        onlineID = ""
        model.consoles.psnAccountIDBase64 = nil
    }

    private func pair() async {
        error = nil
        guard let account = PSNAccount.decode(base64OrDecimal: accountID.trimmingCharacters(in: .whitespacesAndNewlines)),
            account.count == 8
        else {
            error = "Enter an 8-byte account ID in Base64 or decimal."
            return
        }
        isPairing = true
        defer { isPairing = false }
        do {
            let (console, credentials) = try await ConsolePairing.pair(host: trimmedHost, accountID: account, pin: pin)
            try Task.checkCancellation()
            try model.consoles.save(console, credentials: credentials)
            model.consoles.psnAccountIDBase64 = account.base64EncodedString()
            await model.discover()
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            let text = error.localizedDescription
            if text.contains("Invalid PSN ID") {
                signOut()
                self.error = "Sign in with the PlayStation account that opened Pair Device."
            } else {
                self.error = "Pairing failed. \(text)"
            }
        }

    }
}
