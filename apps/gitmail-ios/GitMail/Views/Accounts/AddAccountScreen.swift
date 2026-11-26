import MailAccounts
import MailCore
import SwiftUI
import UIKit

/// Add an iCloud account or any IMAP account (GKM-010): both servers are checked before
/// anything is saved; the password goes to this device's Keychain only.
struct AddAccountScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
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
                        .accessibilityLabel("Email address")
                        .accessibilityIdentifier("addressField")
                    SecureField(draft.provider == .iCloud ? "App-specific password" : "Password or app password", text: $draft.password)
                        .textContentType(.password)
                        .accessibilityLabel(draft.provider == .iCloud ? "App-specific password" : "Password")
                        .accessibilityIdentifier("passwordField")
                } footer: {
                    passwordNote
                }

                Section {
                    // On mail you send (MAIL-074); the account name is only for this app.
                    TextField("Your name", text: $draft.senderName)
                        .textContentType(.name)
                        .accessibilityLabel("Your name")
                        .accessibilityIdentifier("senderNameField")
                    // A fixed prompt: the address as a placeholder was cut off (GKM-061).
                    TextField("Account name (optional)", text: $draft.name)
                        .accessibilityIdentifier("nameField")
                } footer: {
                    Text(draft.displayName.isEmpty ? "Your name is what people see on mail you send."
                         : "Your name is what people see on mail you send. Without an account name, the account is called \(draft.displayName) here.")
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
                        .accessibilityElement(children: .combine)
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
                // The number pad has no Return: a way to put the keyboard away (GKM-061).
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .accessibilityIdentifier("keyboardDone")
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
                serverField("imap.example.com", text: $draft.imapHost)
                    .keyboardType(.URL)
                    .accessibilityLabel("Incoming server (IMAP)")
                    .accessibilityIdentifier("imapHostField")
            }
            LabeledContent("Port") {
                TextField("993", value: $draft.imapPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityLabel("Incoming port")
                    .accessibilityIdentifier("imapPortField")
            }
            LabeledContent("Outgoing (SMTP)") {
                serverField("smtp.example.com", text: $draft.smtpHost)
                    .keyboardType(.URL)
                    .accessibilityLabel("Outgoing server (SMTP)")
                    .accessibilityIdentifier("smtpHostField")
            }
            LabeledContent("Port") {
                TextField("587", value: $draft.smtpPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    .accessibilityLabel("Outgoing port")
                    .accessibilityIdentifier("smtpPortField")
            }
            Picker("Security", selection: $draft.smtpSecurity) {
                Text("TLS").tag(MailServerSecurity.implicitTLS)
                Text("STARTTLS").tag(MailServerSecurity.startTLS)
            }
            .accessibilityIdentifier("smtpSecurityPicker")
            LabeledContent("User name") {
                // A short prompt: the address as a placeholder was cut off at the large sizes.
                serverField("Optional", text: $draft.username)
                    .accessibilityLabel("User name")
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("Without a user name, Mail signs in with your email address. Connections are always encrypted, and the certificate is checked. Plain-text connections aren’t offered.")
        }
    }

    /// A host or user name. At the accessibility sizes it wraps under its label instead of
    /// being cut to "imap.example…" (GKM-061); a line break can't get into it.
    private func serverField(_ prompt: String, text: Binding<String>) -> some View {
        let large = typeSize.isAccessibilitySize
        let oneLine = Binding(get: { text.wrappedValue },
                              set: { text.wrappedValue = $0.replacingOccurrences(of: "\n", with: "") })
        return TextField(prompt, text: oneLine, axis: large ? .vertical : .horizontal)
            .multilineTextAlignment(large ? .leading : .trailing)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func add() {
        error = nil
        isVerifying = true
        let draft = draft
        task = Task {
            defer { isVerifying = false }
            // VoiceOver hears the check start and how it ended; the sheet changes out of sight.
            AccessibilityNotification.Announcement("Checking the incoming and outgoing servers").post()
            do throws(AccountSetupError) {
                try await model.addAccount(draft)
                dismiss()
            } catch {
                self.error = error
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}
