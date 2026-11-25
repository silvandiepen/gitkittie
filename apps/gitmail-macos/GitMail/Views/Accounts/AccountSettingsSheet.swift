import MailCore
import SwiftUI

/// An account's settings (GKM-042): the name on mail you send (MAIL-074), the account's name in
/// the sidebar, and whether mail deleted at the provider is removed here too (MAIL-075).
struct AccountSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let account: MailAccount
    @State private var senderName = ""
    @State private var accountName = ""
    @State private var removesDeleted = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "\(account.displayName) Settings", detail: account.address)
            SettingsPanel {
                FieldRow(label: "Your name") {
                    TextField("Your name", text: $senderName, prompt: Text("As people see it on your mail"))
                        .textContentType(.name)
                        .labelsHidden()
                }
                SettingsDivider()
                FieldRow(label: "Account name") {
                    TextField("Account name", text: $accountName, prompt: Text(account.displayName))
                        .labelsHidden()
                }
            }
            Text(senderName.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Mail you send shows only your address."
                 : "Mail you send shows “\(senderName.trimmingCharacters(in: .whitespaces))” and your address.")
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
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            senderName = account.senderName ?? ""
            accountName = account.displayName
            removesDeleted = account.removesDeletedMail
        }
    }

    private func save() {
        error = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.updateAccountSettings(account.id, displayName: accountName, senderName: senderName,
                                                      removesMailDeletedElsewhere: removesDeleted)
                dismiss()
            } catch {
                self.error = "The settings couldn’t be saved: \(error.localizedDescription)"
            }
        }
    }
}
