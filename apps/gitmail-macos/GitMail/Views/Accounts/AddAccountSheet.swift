import MailAccounts
import MailCore
import SwiftUI

/// Add an iCloud account or any IMAP account (GKM-010). Checks both servers before saving; the
/// password goes to the Keychain only.
struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AccountDraft()
    @State private var error: AccountSetupError?
    @State private var isVerifying = false
    @State private var chosenFolder: URL?
    /// Why the folder just picked can't hold the mail (GKM-103); cleared by the next pick.
    @State private var folderRefusal: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                title: "Add an Account",
                detail: "GitKittie Mail connects to your provider directly and keeps a copy of your mail in a folder on this Mac. Your password stays in this Mac’s Keychain."
            )

            Picker("Account", selection: $draft.provider) {
                Text("iCloud").tag(AccountDraft.Provider.iCloud)
                Text("Other IMAP").tag(AccountDraft.Provider.other)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draft.provider) { _, _ in
                error = nil
                draft.suggestServers()
            }

            SettingsPanel {
                FieldRow(label: "Email address") {
                    TextField("Email address", text: $draft.address,
                              prompt: Text(draft.provider == .iCloud ? "you@icloud.com" : "you@example.com"))
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .labelsHidden()
                }
                SettingsDivider()
                FieldRow(label: draft.provider == .iCloud ? "App-specific password" : "Password") {
                    SecureField("Password", text: $draft.password, prompt: Text(draft.provider == .iCloud ? "xxxx-xxxx-xxxx-xxxx" : "Password or app password"))
                        .labelsHidden()
                }
                SettingsDivider()
                // On mail you send (MAIL-074); the account name below is only for the sidebar.
                FieldRow(label: "Your name") {
                    TextField("Your name", text: $draft.senderName, prompt: Text("As people see it on your mail"))
                        .textContentType(.name)
                        .labelsHidden()
                }
                SettingsDivider()
                FieldRow(label: "Account name") {
                    TextField("Account name", text: $draft.name, prompt: Text(draft.displayName.isEmpty ? "Optional" : draft.displayName))
                        .labelsHidden()
                }
            }
            .onChange(of: draft.address) { old, _ in
                var previous = draft
                previous.address = old
                previous.suggestServers()
                draft.suggestServers(previous: previous)
            }

            passwordNote

            if draft.provider == .other { servers }

            if model.accounts.isEmpty { mailFolder }

            if let error { SheetError(message: error.message) }

            HStack {
                if isVerifying {
                    ProgressView().controlSize(.small)
                    Text("Checking the incoming and outgoing servers…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    // Stops a check in progress; an account is only saved after it passes.
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add Account") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isVerifying || draft.trimmedAddress.isEmpty || draft.password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    /// What the provider asks for, with its page on app passwords.
    @ViewBuilder private var passwordNote: some View {
        if let preset = draft.preset {
            VStack(alignment: .leading, spacing: 4) {
                if draft.provider == .other {
                    Text("\(preset.name) settings are filled in.").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(preset.passwordNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let help = preset.appPasswordHelp {
                    Link(preset.kind == .iCloud ? "About app-specific passwords" : "About app passwords", destination: help)
                        .font(.caption)
                }
            }
        } else if draft.provider == .other {
            Text("If your provider offers app passwords, use one instead of your main password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Servers").font(.subheadline.weight(.medium))
            SettingsPanel {
                FieldRow(label: "Incoming (IMAP)") {
                    HStack(spacing: 8) {
                        TextField("Incoming server", text: $draft.imapHost, prompt: Text("imap.example.com"))
                            .autocorrectionDisabled().labelsHidden()
                        TextField("Port", value: $draft.imapPort, format: .number.grouping(.never))
                            .frame(width: 56).labelsHidden()
                        Text("TLS").font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsDivider()
                FieldRow(label: "Outgoing (SMTP)") {
                    HStack(spacing: 8) {
                        TextField("Outgoing server", text: $draft.smtpHost, prompt: Text("smtp.example.com"))
                            .autocorrectionDisabled().labelsHidden()
                        TextField("Port", value: $draft.smtpPort, format: .number.grouping(.never))
                            .frame(width: 56).labelsHidden()
                        Picker("Security", selection: $draft.smtpSecurity) {
                            Text("TLS").tag(MailServerSecurity.implicitTLS)
                            Text("STARTTLS").tag(MailServerSecurity.startTLS)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                SettingsDivider()
                FieldRow(label: "User name") {
                    TextField("User name", text: $draft.username, prompt: Text(draft.trimmedAddress.isEmpty ? "Your email address" : draft.trimmedAddress))
                        .autocorrectionDisabled().labelsHidden()
                }
            }
            Text("Connections are always encrypted, and the certificate is checked. Plain-text connections aren’t offered.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The first account decides where the mail folder is (MAIL-021).
    private var mailFolder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mail folder").font(.subheadline.weight(.medium))
            SettingsPanel {
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chosenFolder?.lastPathComponent ?? "Mail, inside GitKittie Mail")
                        Text(chosenFolder == nil
                             ? "Only GitKittie Mail can read it there."
                             : "Other apps and sync tools that can read this folder can read your mail.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if chosenFolder != nil {
                        Button("Use Default") { chosenFolder = nil }.controlSize(.small)
                    }
                    Button("Choose…") { chooseFolder() }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            if let folderRefusal { SheetError(message: folderRefusal) }
        }
    }

    private func chooseFolder() {
        Task {
            guard let url = await Platform.chooseFolder(
                title: "Choose a Mail Folder", prompt: "Use Folder",
                message: "GitKittie Mail keeps each message as an .eml file with a readable Markdown copy beside it.") else { return }
            folderRefusal = nil
            // iCloud Drive and folders other apps sync can't hold the mail yet (GKM-103).
            if let reason = model.mailFolderRefusal(for: url) {
                folderRefusal = reason
                return
            }
            chosenFolder = url
        }
    }

    private func add() {
        error = nil
        isVerifying = true
        task = Task {
            defer { isVerifying = false }
            if let chosenFolder { await model.useMailFolder(chosenFolder) }
            do {
                try await model.addAccount(draft)
                draft.password = ""
                dismiss()
            } catch AccountSetupError.cancelled {
                return
            } catch let failure as AccountSetupError {
                error = failure
            } catch {
                self.error = .refused(.incoming, host: "", detail: error.localizedDescription)
            }
        }
    }
}
