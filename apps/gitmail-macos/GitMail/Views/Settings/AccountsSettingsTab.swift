import MailAccounts
import MailCore
import SwiftUI

/// Settings ▸ Accounts (GKM-066): the accounts on the left (add, remove, drag to reorder), the
/// chosen one's information, mailboxes and servers on the right, as in Apple Mail.
struct AccountsSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsNavigation.self) private var navigation
    @State private var removing: MailAccount?
    @State private var error: String?

    private var selected: MailAccount? {
        navigation.account.flatMap { id in model.accounts.first { $0.id == id } }
    }

    var body: some View {
        @Bindable var navigation = navigation
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $navigation.account) {
                    ForEach(model.accounts) { account in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName).lineLimit(1)
                            if !account.address.isEmpty, account.address != account.displayName {
                                Text(account.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(account.id)
                    }
                    .onMove { source, destination in
                        Task {
                            do { try await model.moveAccounts(fromOffsets: source, toOffset: destination) } catch {
                                self.error = "The order couldn’t be saved: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                .listStyle(.bordered)
                .accessibilityIdentifier("settingsAccountList")
                HStack(spacing: 0) {
                    Button { navigation.addsAccount = true } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add an account")
                        .accessibilityLabel("Add Account")
                    Button { removing = selected } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .help("Remove the account")
                        .accessibilityLabel("Remove Account")
                        .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
                if let error { SheetError(message: error).font(.caption).padding(.top, 6) }
            }
            .frame(width: 210)

            Group {
                if let account = selected {
                    AccountSettingsDetail(account: account)
                        .id(account.id)
                } else {
                    VStack(spacing: 8) {
                        Text(model.accounts.isEmpty ? "No accounts yet" : "Choose an account").font(.title3)
                        if model.accounts.isEmpty {
                            Button("Add an Account…") { navigation.addsAccount = true }
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: 520)
        .sheet(isPresented: $navigation.addsAccount) { AddAccountSheet() }
        .sheet(item: $removing) { RemoveAccountSheet(account: $0) }
        .onAppear { if selected == nil { navigation.account = model.accounts.first?.id } }
        .onChange(of: model.accounts.map(\.id)) { _, ids in
            if let id = navigation.account, ids.contains(id) { return }
            navigation.account = ids.first
        }
    }
}

/// One account: its information, its mailboxes, its servers.
private struct AccountSettingsDetail: View {
    @Environment(SettingsNavigation.self) private var navigation
    let account: MailAccount

    var body: some View {
        @Bindable var navigation = navigation
        VStack(alignment: .leading, spacing: 14) {
            Picker("Show", selection: $navigation.accountPane) {
                ForEach(AccountSettingsPane.allCases, id: \.self) { pane in Text(pane.title).tag(pane) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            switch navigation.accountPane {
            case .information: AccountInformationPane(account: account)
            case .mailboxes: AccountMailboxesPane(account: account)
            case .servers: AccountServersPane(account: account)
            }
        }
    }
}

/// The account's names, what happens to mail deleted elsewhere, its sync, and its password.
private struct AccountInformationPane: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount
    @State private var accountName = ""
    @State private var senderName = ""
    @State private var removesDeleted = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var password = ""
    @State private var passwordError: String?
    @State private var passwordSaved = false
    @State private var isCheckingPassword = false

    private var isChanged: Bool {
        accountName.trimmingCharacters(in: .whitespaces) != account.displayName
            || senderName.trimmingCharacters(in: .whitespaces) != (account.senderName ?? "")
            || removesDeleted != account.removesDeletedMail
    }

    private var isICloud: Bool { account.connection?.kind == .iCloud }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsPanel {
                    FieldRow(label: "Email address") {
                        Text(account.address.isEmpty ? "—" : account.address).textSelection(.enabled)
                    }
                    SettingsDivider()
                    FieldRow(label: "Account name") {
                        TextField("Account name", text: $accountName, prompt: Text(account.displayName))
                            .labelsHidden()
                            .accessibilityIdentifier("settingsAccountName")
                    }
                    SettingsDivider()
                    FieldRow(label: "Your name") {
                        TextField("Your name", text: $senderName, prompt: Text("As people see it on your mail"))
                            .textContentType(.name)
                            .labelsHidden()
                            .accessibilityIdentifier("settingsSenderName")
                    }
                }
                Text(senderName.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Mail you send shows only your address. The account name is only for the sidebar."
                     : "Mail you send shows “\(senderName.trimmingCharacters(in: .whitespaces))” and your address. The account name is only for the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Remove mail deleted elsewhere", isOn: $removesDeleted)
                    Text(removesDeleted
                         ? "When a message is deleted in another app or on the web, its copy on this Mac is removed too, on the next sync. Pinned mail and mail in a space stay."
                         : "When a message is deleted in another app or on the web, its copy on this Mac stays, marked “Deleted at \(ProviderDeletionText.providerName(of: account))” with the time.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error { SheetError(message: error) }
                HStack {
                    if let status = model.syncStatus(account.id) {
                        Text(status).font(.caption)
                            .foregroundStyle(model.needsPassword(account.id) ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("Revert") { load() }.disabled(!isChanged || isSaving)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isChanged || isSaving)
                }

                if account.connection != nil { passwordSection }
            }
            .padding(.trailing, 4)
        }
        .onAppear(perform: load)
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Password").font(.subheadline.weight(.medium))
            SettingsPanel {
                FieldRow(label: isICloud ? "App-specific password" : "New password") {
                    SecureField("New password", text: $password, prompt: Text(isICloud ? "xxxx-xxxx-xxxx-xxxx" : "Password or app password"))
                        .labelsHidden()
                        .accessibilityIdentifier("settingsNewPassword")
                }
            }
            HStack(alignment: .top) {
                Text(model.needsPassword(account.id)
                     ? "The provider refused the saved password. Enter the current one; it is checked before it replaces the one in this Mac’s Keychain."
                     : "Only needed when you changed the password or revoked the app password. It is checked first, then kept in this Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if isCheckingPassword { ProgressView().controlSize(.small) }
                Button("Check and Save") { savePassword() }
                    .disabled(password.isEmpty || isCheckingPassword)
            }
            if let passwordError { SheetError(message: passwordError) }
            if passwordSaved { Label("Saved in the Keychain.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        accountName = account.displayName
        senderName = account.senderName ?? ""
        removesDeleted = account.removesDeletedMail
        error = nil
    }

    private func save() {
        error = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.updateAccountSettings(account.id, displayName: accountName, senderName: senderName,
                                                      removesMailDeletedElsewhere: removesDeleted)
            } catch {
                self.error = "The settings couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }

    private func savePassword() {
        passwordError = nil
        passwordSaved = false
        isCheckingPassword = true
        Task {
            defer { isCheckingPassword = false }
            do throws(AccountSetupError) {
                try await model.updatePassword(password, for: account.id)
                password = ""
                passwordSaved = true
            } catch {
                passwordError = error.message
            }
        }
    }
}

/// The incoming and outgoing servers. Both are checked with the password before anything is
/// saved (MAIL-096). iCloud's are fixed.
private struct AccountServersPane: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount
    @State private var imap = MailServerSettings(host: "", port: 993, security: .implicitTLS, username: "")
    @State private var smtp = MailServerSettings(host: "", port: 587, security: .startTLS, username: "")
    @State private var password = ""
    @State private var isChecking = false
    @State private var error: String?
    @State private var saved = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        if let connection = account.connection {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if connection.kind == .iCloud {
                        Text("iCloud’s servers are set by Apple.").font(.callout).foregroundStyle(.secondary)
                    }
                    server("Incoming (IMAP)", settings: $imap, securityChoice: false)
                    server("Outgoing (SMTP)", settings: $smtp, securityChoice: true)
                    if connection.kind != .iCloud {
                        SettingsPanel {
                            FieldRow(label: "Password") {
                                SecureField("Password", text: $password, prompt: Text("Leave empty to keep the saved one"))
                                    .labelsHidden()
                            }
                        }
                        Text("Connections are always encrypted, and the certificate is checked. Both servers are checked before the change is saved; the sync then starts again with them.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error { SheetError(message: error) }
                        if saved { Label("Checked and saved.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            if isChecking {
                                ProgressView().controlSize(.small)
                                Text("Checking the incoming and outgoing servers…").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revert") { load(connection) }.disabled(isChecking || !isChanged(connection))
                            Button(isChecking ? "Stop" : "Check and Save") {
                                if isChecking { task?.cancel() } else { save() }
                            }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!isChecking && !isChanged(connection) && password.isEmpty)
                        }
                    }
                }
                .disabled(connection.kind == .iCloud)
                .padding(.trailing, 4)
            }
            .onAppear { load(connection) }
        } else {
            Text("This account isn’t connected: its mail is kept on this Mac and nothing syncs it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func server(_ title: String, settings: Binding<MailServerSettings>, securityChoice: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            SettingsPanel {
                FieldRow(label: "Server") {
                    HStack(spacing: 8) {
                        TextField("Server", text: settings.host).autocorrectionDisabled().labelsHidden()
                        TextField("Port", value: settings.port, format: .number.grouping(.never)).frame(width: 56).labelsHidden()
                        if securityChoice {
                            Picker("Security", selection: settings.security) {
                                Text("TLS").tag(MailServerSecurity.implicitTLS)
                                Text("STARTTLS").tag(MailServerSecurity.startTLS)
                            }
                            .labelsHidden()
                            .fixedSize()
                        } else {
                            Text("TLS").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsDivider()
                FieldRow(label: "User name") {
                    TextField("User name", text: settings.username).autocorrectionDisabled().labelsHidden()
                }
            }
        }
    }

    private func isChanged(_ connection: MailConnectionSettings) -> Bool {
        imap != connection.imap || smtp != connection.smtp
    }

    private func load(_ connection: MailConnectionSettings) {
        imap = connection.imap
        smtp = connection.smtp
        password = ""
        error = nil
    }

    private func save() {
        error = nil
        saved = false
        isChecking = true
        task = Task {
            defer { isChecking = false }
            do throws(AccountSetupError) {
                try await model.updateServers(account.id, imap: imap, smtp: smtp, password: password)
                password = ""
                saved = true
            } catch .cancelled {
                return
            } catch {
                self.error = error.message
            }
        }
    }
}
