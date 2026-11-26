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
    @Environment(MailWindowRequests.self) private var requests
    @Environment(SettingsNavigation.self) private var settings

    var body: some View {
        Section("Accounts") {
            if model.accounts.isEmpty {
                Button {
                    requests.accountSheet = .add
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
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                        .selectionDisabled()
                }
            }
        }
    }

    /// The folders the account shows, in its order (Settings ▸ Accounts ▸ Mailboxes, MAIL-093).
    @MainActor static func folders(of account: MailAccount, model: AppModel) -> [SyncedFolder] {
        model.sidebarFolders(of: account)
    }

    /// The Mailbox menu's account items, for this account.
    @ViewBuilder private func menu(for account: MailAccount) -> some View {
        if account.connection != nil {
            Button("Sync Now") { Task { await model.sync.syncNow() } }
            Divider()
        }
        AccountMenuItems(model: model, requests: requests, settings: settings, account: account)
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

    private var icon: String { FolderLook.icon(folder.role) }
}
