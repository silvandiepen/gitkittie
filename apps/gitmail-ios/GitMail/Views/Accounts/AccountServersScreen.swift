import MailAccounts
import MailCore
import SwiftUI

/// An account's incoming and outgoing servers (GKM-066, MAIL-096). Both are checked with the
/// password before anything is saved; iCloud's are set by Apple.
struct AccountServersScreen: View {
    @Environment(AppModel.self) private var model
    let accountID: MailAccountID
    @State private var imap = MailServerSettings(host: "", port: 993, security: .implicitTLS, username: "")
    @State private var smtp = MailServerSettings(host: "", port: 587, security: .startTLS, username: "")
    @State private var password = ""
    @State private var isChecking = false
    @State private var error: String?
    @State private var saved = false

    private var account: MailAccount? { model.accounts.first { $0.id == accountID } }

    var body: some View {
        Form {
            if let connection = account?.connection {
                let fixed = connection.kind == .iCloud
                // Each field keeps its name beside it once it has a value (a placeholder alone
                // disappears), and VoiceOver hears which server it belongs to (GKM-061).
                Section("Incoming (IMAP)") {
                    field("Server", "Incoming server", text: $imap.host)
                    portField("Incoming port", value: $imap.port)
                    field("User name", "Incoming user name", text: $imap.username)
                }
                .disabled(fixed)
                Section("Outgoing (SMTP)") {
                    field("Server", "Outgoing server", text: $smtp.host)
                    portField("Outgoing port", value: $smtp.port)
                    Picker("Security", selection: $smtp.security) {
                        Text("TLS").tag(MailServerSecurity.implicitTLS)
                        Text("STARTTLS").tag(MailServerSecurity.startTLS)
                    }
                    field("User name", "Outgoing user name", text: $smtp.username)
                }
                .disabled(fixed)
                if fixed {
                    Section { Text("iCloud’s servers are set by Apple.").foregroundStyle(.secondary) }
                } else {
                    Section {
                        SecureField("Password (leave empty to keep it)", text: $password).textContentType(.password)
                        Button {
                            save()
                        } label: {
                            if isChecking { ProgressView().accessibilityLabel("Checking") } else { Text("Check and Save") }
                        }
                        .disabled(isChecking || (imap == connection.imap && smtp == connection.smtp && password.isEmpty))
                        if let error { NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: error) }
                        if saved { Label("Checked and saved.", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    } footer: {
                        Text("Connections are always encrypted, and the certificate is checked. Both servers are checked before the change is saved; the sync then starts again with them.")
                    }
                }
            } else {
                Section { Text("This account isn’t connected: its mail is kept on \(DeviceWords.this) and nothing syncs it.").foregroundStyle(.secondary) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("Servers")
        .onAppear {
            guard let connection = account?.connection else { return }
            imap = connection.imap
            smtp = connection.smtp
        }
    }

    private func field(_ title: String, _ spoken: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel(spoken)
        }
    }

    private func portField(_ spoken: String, value: Binding<Int>) -> some View {
        LabeledContent("Port") {
            TextField("Port", value: value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .accessibilityLabel(spoken)
        }
    }

    private func save() {
        error = nil
        saved = false
        isChecking = true
        Task {
            defer { isChecking = false }
            do throws(AccountSetupError) {
                try await model.updateServers(accountID, imap: imap, smtp: smtp, password: password)
                password = ""
                saved = true
            } catch {
                self.error = error.message
            }
        }
    }
}
