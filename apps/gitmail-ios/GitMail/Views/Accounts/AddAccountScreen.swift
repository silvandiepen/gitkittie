import MailAccounts
import MailCore
import SwiftUI

/// Add an iCloud account or any IMAP account (GKM-010): both servers are checked before
/// anything is saved; the password goes to this device's Keychain only.
struct AddAccountScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AccountDraft()
    @State private var error: AccountSetupError?
    @State private var isVerifying = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Account", selection: $draft.provider) {
                        Text("iCloud").tag(AccountDraft.Provider.iCloud)
                        Text("Other IMAP").tag(AccountDraft.Provider.other)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("providerPicker")
                } footer: {
                    Text("Mail connects to your provider directly and keeps a copy of your mail on \(DeviceWords.this). Your password stays in its Keychain.")
                }

                Section {
                    TextField(draft.provider == .iCloud ? "you@icloud.com" : "you@example.com", text: $draft.address)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("addressField")
                    SecureField(draft.provider == .iCloud ? "App-specific password" : "Password or app password", text: $draft.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("passwordField")
                } footer: {
                    passwordNote
                }

                Section {
                    // On mail you send (MAIL-074); the account name is only for this app.
                    TextField("Your name", text: $draft.senderName)
                        .textContentType(.name)
                        .accessibilityIdentifier("senderNameField")
                    TextField(draft.displayName.isEmpty ? "Account name (optional)" : draft.displayName, text: $draft.name)
                        .accessibilityIdentifier("nameField")
                } footer: {
                    Text("Your name is what people see on mail you send.")
                }

                if draft.provider == .other { servers }

                if let error {
                    Section {
                        NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: error.message)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("accountError")
                    }
                }

                if isVerifying {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking the incoming and outgoing servers…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.window.ignoresSafeArea())
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Stops a check in progress; an account is only saved after it passes.
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(isVerifying || draft.trimmedAddress.isEmpty || draft.password.isEmpty)
                        .accessibilityIdentifier("addAccountConfirm")
                }
            }
            .onChange(of: draft.provider) { _, _ in
                error = nil
                draft.suggestServers()
            }
            .onChange(of: draft.address) { old, _ in
                var previous = draft
                previous.address = old
                previous.suggestServers()
                draft.suggestServers(previous: previous)
            }
        }
    }

    /// What the provider asks for, with its page on app passwords.
    @ViewBuilder private var passwordNote: some View {
        if let preset = draft.preset {
            VStack(alignment: .leading, spacing: 4) {
                if draft.provider == .other { Text("\(preset.name) settings are filled in.") }
                Text(preset.passwordNote)
                if let help = preset.appPasswordHelp {
                    Link(preset.kind == .iCloud ? "About app-specific passwords" : "About app passwords", destination: help)
                }
            }
        } else if draft.provider == .other {
            Text("If your provider offers app passwords, use one instead of your main password.")
        }
    }

    private var servers: some View {
        Section {
            LabeledContent("Incoming (IMAP)") {
                TextField("imap.example.com", text: $draft.imapHost)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("imapHostField")
            }
            LabeledContent("Port") {
                TextField("993", value: $draft.imapPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityIdentifier("imapPortField")
            }
            LabeledContent("Outgoing (SMTP)") {
                TextField("smtp.example.com", text: $draft.smtpHost)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("smtpHostField")
            }
            LabeledContent("Port") {
                TextField("587", value: $draft.smtpPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityIdentifier("smtpPortField")
            }
            Picker("Security", selection: $draft.smtpSecurity) {
                Text("TLS").tag(MailServerSecurity.implicitTLS)
                Text("STARTTLS").tag(MailServerSecurity.startTLS)
            }
            .accessibilityIdentifier("smtpSecurityPicker")
            LabeledContent("User name") {
                TextField(draft.trimmedAddress.isEmpty ? "Your email address" : draft.trimmedAddress, text: $draft.username)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("Connections are always encrypted, and the certificate is checked. Plain-text connections aren’t offered.")
        }
    }

    private func add() {
        error = nil
        isVerifying = true
        let draft = draft
        task = Task {
            defer { isVerifying = false }
            do throws(AccountSetupError) {
                try await model.addAccount(draft)
                dismiss()
            } catch {
                self.error = error
            }
        }
    }
}
