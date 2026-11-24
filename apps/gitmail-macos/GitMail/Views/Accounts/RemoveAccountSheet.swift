import MailAccounts
import MailCore
import SwiftUI

/// Remove an account, choosing what happens to its mail on this Mac (GKM-010). Mail at the
/// provider is never touched.
struct RemoveAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: MailAccount

    enum Choice: Hashable { case keep, export, remove }
    @State private var choice = Choice.keep
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                title: "Remove \(account.displayName)?",
                detail: "GitKittie Mail stops syncing \(account.address.isEmpty ? "this account" : account.address) and removes its password from this Mac. Nothing is deleted at your provider."
            )

            SettingsPanel {
                option(.keep, "Keep its mail on this Mac",
                       "The messages stay in your mail folder, readable and searchable. Nothing syncs them any more.")
                SettingsDivider()
                option(.export, "Export a copy, then remove it",
                       "Saves the messages and attachments to a folder you choose, then removes them from the mail folder.")
                SettingsDivider()
                option(.remove, "Remove its mail from this Mac",
                       "Deletes the messages and the attachments only they use from the mail folder. This can’t be undone here.")
            }

            if let error { SheetError(message: error) }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(choice == .keep ? "Remove Account" : "Remove Account and Mail", role: .destructive) { remove() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func option(_ value: Choice, _ title: String, _ detail: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Theme.accent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == value ? [.isSelected] : [])
    }

    private func remove() {
        error = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            let removal: AccountRemoval
            switch choice {
            case .keep:
                removal = .keepMail
            case .remove:
                removal = .removeMail
            case .export:
                guard let folder = await Platform.chooseFolder(
                    title: "Export \(account.displayName)", prompt: "Export Here",
                    message: "A folder named “\(account.displayName) Mail” is made here with every message and attachment.") else { return }
                removal = .exportThenRemove(folder)
            }
            do {
                try await model.removeAccount(account.id, removal)
                dismiss()
            } catch {
                self.error = "The account couldn’t be removed: \(error.localizedDescription)"
            }
        }
    }
}

/// A new password for an account whose provider refused the old one.
struct UpdatePasswordSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: MailAccount
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?

    private var isICloud: Bool { account.connection?.kind == .iCloud }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                title: "Sign In to \(account.displayName) Again",
                detail: isICloud
                    ? "iCloud no longer accepts the saved app-specific password. Changing your Apple Account password revokes them; make a new one at account.apple.com."
                    : "\(account.address) no longer accepts the saved password. Enter the current one."
            )
            SettingsPanel {
                FieldRow(label: isICloud ? "App-specific password" : "Password") {
                    SecureField("Password", text: $password).labelsHidden()
                }
            }
            if let error { SheetError(message: error) }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func signIn() {
        error = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await model.updatePassword(password, for: account.id)
                password = ""
                dismiss()
            } catch {
                self.error = (error as? AccountSetupError)?.message ?? error.localizedDescription
            }
        }
    }
}
