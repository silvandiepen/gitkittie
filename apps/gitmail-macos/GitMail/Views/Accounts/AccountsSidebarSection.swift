import MailCore
import MailStore
import SwiftUI

/// The sheets the sidebar opens for accounts.
enum AccountSheet: Identifiable {
    case add
    case remove(MailAccount)
    case signIn(MailAccount)

    var id: String {
        switch self {
        case .add: "add"
        case .remove(let account): "remove-\(account.id.rawValue)"
        case .signIn(let account): "sign-in-\(account.id.rawValue)"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .add: AddAccountSheet()
        case .remove(let account): RemoveAccountSheet(account: account)
        case .signIn(let account): UpdatePasswordSheet(account: account)
        }
    }
}

/// Each account with its sync status, then its folders at the provider (GKM-010, GKM-011).
struct AccountsSidebarSection: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: AccountSheet?

    var body: some View {
        Section("Accounts") {
            if model.accounts.isEmpty {
                Button {
                    sheet = .add
                } label: {
                    Label("Add an Account…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 2)
                .selectionDisabled()
            }
            ForEach(model.accounts) { account in
                AccountRow(account: account, status: model.syncStatus(account.id), needsPassword: model.needsPassword(account.id))
                    .tag(SidebarSelection.account(account.id))
                    .contextMenu { menu(for: account) }
                let folders = Self.folders(of: account, model: model)
                ForEach(folders, id: \.name) { folder in
                    FolderRow(folder: folder)
                        .tag(SidebarSelection.folder(account.id, folder.name))
                        .contextMenu { menu(for: account) }
                        // Drop conversations on a folder to move them there (GKM-015).
                        .movesDroppedConversations(to: folder, of: account.id, model: model)
                }
                if folders.isEmpty, account.connection != nil {
                    Text("Folders appear after the first sync.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 30)
                        .selectionDisabled()
                }
            }
        }
    }

    /// The provider's folders once the sync has listed them; before that (or for an account
    /// that no longer syncs) the folders that hold stored mail.
    @MainActor static func folders(of account: MailAccount, model: AppModel) -> [SyncedFolder] {
        if let synced = model.sync.folders[account.id], !synced.isEmpty { return synced }
        return (model.folders[account.id] ?? []).map { name in
            SyncedFolder(name: name, path: [name], role: name.caseInsensitiveCompare("INBOX") == .orderedSame ? "inbox" : nil)
        }
    }

    @ViewBuilder private func menu(for account: MailAccount) -> some View {
        if model.needsPassword(account.id) {
            Button("Sign In Again…") { sheet = .signIn(account) }
        }
        if account.connection != nil {
            Button("Sync Now") { Task { await model.sync.syncNow() } }
        }
        Button("Export Account…") { Task { await Platform.export(.account(account.id), what: account.displayName, model: model) } }
        if (model.sync.replay[account.id]?.status.failed ?? 0) > 0 {
            Button("Try Failed Changes Again") { Task { await model.actions.retryFailed(account: account.id) } }
            Button("Discard Failed Changes") { Task { await model.actions.discardFailed(account: account.id) } }
        }
        Divider()
        Button("Remove Account…") { sheet = .remove(account) }
    }
}

private struct AccountRow: View {
    let account: MailAccount
    let status: String?
    let needsPassword: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName).font(.body).lineLimit(1)
                if !account.address.isEmpty, account.address != account.displayName {
                    Text(account.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(needsPassword ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct FolderRow: View {
    let folder: SyncedFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(folder.role == "inbox" ? "Inbox" : folder.path.joined(separator: " / "))
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.leading, 22)
        .padding(.vertical, 1)
    }

    private var icon: String {
        switch folder.role {
        case "inbox": "tray"
        case "sent": "paperplane"
        case "drafts": "doc"
        case "archive": "archivebox"
        case "trash": "trash"
        case "junk": "xmark.bin"
        case "flagged": "flag"
        case "all": "tray.2"
        default: "folder"
        }
    }
}
