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
            do {
                try await model.updatePassword(password, for: accountID)
                password = ""
            } catch {
                passwordError = error.message
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
