import MailAccounts
import MailCore
import SwiftUI

/// One account: how its sync is doing, a new password when the provider refused the old one,
/// and removing it from this device. Nothing here changes anything at the provider.
struct AccountScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: MailAccountID
    @State private var password = ""
    @State private var passwordError: String?
    @State private var isSaving = false
    @State private var confirmingRemoval = false
    @State private var senderName = ""
    @State private var settingsError: String?

    private var account: MailAccount? { model.accounts.first { $0.id == accountID } }

    var body: some View {
        Form {
            if let account {
                Section {
                    LabeledContent("Address", value: account.address.isEmpty ? "—" : account.address)
                    if let status = model.syncStatus(accountID) {
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let failed = model.sync.replay[accountID]?.status.failed, failed > 0 {
                        Button("Try the Changes Again") { Task { await model.actions.retryFailed(account: accountID) } }
                        Button("Drop the Changes", role: .destructive) { Task { await model.actions.discardFailed(account: accountID) } }
                    }
                }
                Section {
                    TextField("Your name", text: $senderName)
                        .textContentType(.name)
                        .onSubmit { saveSettings(account, removes: account.removesDeletedMail) }
                        .accessibilityIdentifier("senderNameField")
                    Toggle("Remove Mail Deleted Elsewhere", isOn: Binding(
                        get: { account.removesDeletedMail },
                        set: { saveSettings(account, removes: $0) }))
                    if let settingsError {
                        NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: settingsError)
                    }
                } header: {
                    Text("Sending and Syncing")
                } footer: {
                    Text(account.removesDeletedMail
                         ? "Your name is what people see on mail you send. Mail deleted in another app or on the web is removed from \(DeviceWords.this) on the next sync; pinned mail and mail in a space stay."
                         : "Your name is what people see on mail you send. Mail deleted in another app or on the web stays on \(DeviceWords.this), marked “Deleted at \(ProviderDeletionText.providerName(of: account))” with the time.")
                }
                if account.connection != nil {
                    Section {
                        SecureField(account.connection?.kind == .iCloud ? "New app-specific password" : "New password", text: $password)
                            .textContentType(.password)
                        Button {
                            save()
                        } label: {
                            if isSaving { ProgressView() } else { Text("Check and Save") }
                        }
                        .disabled(password.isEmpty || isSaving)
                        if let passwordError {
                            NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: passwordError)
                        }
                    } header: {
                        Text("Password")
                    } footer: {
                        Text(model.needsPassword(accountID)
                             ? "The provider refused the saved password. Enter the current one; it is checked before it is saved."
                             : "Only needed when you changed the password or revoked the app password.")
                    }
                }
                Section {
                    Button("Remove from \(DeviceWords.this.capitalizedFirst)…", role: .destructive) { confirmingRemoval = true }
                } footer: {
                    Text("Your mail at the provider is not touched.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle(account?.displayName ?? "Account")
        .onAppear { senderName = account?.senderName ?? "" }
        .onDisappear {
            // A name typed without pressing Return is kept too.
            if let account, (account.senderName ?? "") != senderName.trimmingCharacters(in: .whitespacesAndNewlines) {
                saveSettings(account, removes: account.removesDeletedMail)
            }
        }
        .confirmationDialog("Remove this account?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove, Keep Its Mail Here") { remove(.keepMail) }
            Button("Remove With Its Mail", role: .destructive) { remove(.removeMail) }
        } message: {
            Text("Syncing stops and the password is removed from \(DeviceWords.this). Keeping the mail leaves it readable and searchable here.")
        }
    }

    private func save() {
        isSaving = true
        passwordError = nil
        Task {
            defer { isSaving = false }
            do throws(AccountSetupError) {
                try await model.updatePassword(password, for: accountID)
                password = ""
            } catch {
                passwordError = error.message
            }
        }
    }

    private func saveSettings(_ account: MailAccount, removes: Bool) {
        settingsError = nil
        Task {
            do {
                try await model.updateAccountSettings(account.id, displayName: account.displayName, senderName: senderName,
                                                      removesMailDeletedElsewhere: removes)
            } catch {
                settingsError = "The settings couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }

    private func remove(_ removal: AccountRemoval) {
        Task {
            do {
                try await model.removeAccount(accountID, removal)
                dismiss()
            } catch {
                model.actionError = String(describing: error)
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
