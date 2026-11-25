import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The first column: Focused first, then the other category views and All Mail, then Drafts
/// and the outbox, spaces, and each account with its folders (GKM-018, GKM-022).
struct MailboxesView: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session
    @Environment(MailRouter.self) private var router

    var body: some View {
        List(selection: selection) {
            if let notice = session.storageNotice {
                Section { NoticeLine(systemImage: "externaldrive.badge.exclamationmark", tint: .orange, text: notice) }
            }
            Section {
                ForEach(MailCategory.allCases, id: \.self) { category in
                    MailboxRow(title: category.title, systemImage: category.systemImage, count: count(category))
                        .tag(SidebarSelection.category(category))
                        .accessibilityIdentifier("mailbox.\(category.title)")
                }
                MailboxRow(title: "All Mail", systemImage: "tray.full", count: nil)
                    .tag(SidebarSelection.allMail)
                if model.attention.pendingClassification > 0 {
                    Text("Sorting \(model.attention.pendingClassification.formatted()) messages…")
                        .font(.caption).foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            }
            Section {
                MailboxRow(title: "Drafts", systemImage: "doc", count: draftCount)
                    .tag(SidebarSelection.drafts)
                MailboxRow(title: "Outbox", systemImage: "tray.and.arrow.up", count: outboxCount)
                    .tag(SidebarSelection.outbox)
                    .accessibilityIdentifier("mailbox.Outbox")
            }
            if !model.spaces.spaces.isEmpty {
                Section("Spaces") {
                    ForEach(model.spaces.spaces) { space in
                        MailboxRow(title: space.name, systemImage: space.icon,
                                   count: model.spaces.counts[space.id].flatMap { $0.unread > 0 ? MailboxRow.Count.normal($0.unread) : nil },
                                   tint: SpaceColor.color(space.color))
                            .tag(SidebarSelection.space(space.id))
                    }
                }
            }
            ForEach(model.accounts, id: \.id) { account in
                Section {
                    MailboxRow(title: "All of \(account.displayName)", systemImage: "person.crop.circle", count: nil)
                        .tag(SidebarSelection.account(account.id))
                    ForEach(folders(of: account.id), id: \.self) { folder in
                        MailboxRow(title: folder.role == "inbox" ? "Inbox" : folder.path.joined(separator: " / "),
                                   systemImage: FolderLook.icon(folder.role), count: nil)
                            .tag(SidebarSelection.folder(account.id, folder.name))
                    }
                } header: {
                    AccountHeader(account: account)
                }
            }
            Section {
                Button { router.showsAddAccount = true } label: {
                    Label("Add Account", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("addAccountButton")
            } footer: {
                if model.accounts.isEmpty {
                    Text("Mail connects to your provider directly and keeps every message as a file you own, in On My \(DeviceWords.model) ▸ Mail in Files.")
                }
            }
        }
        .listStyle(.sidebar)
        .themedList()
        .navigationTitle("Mailboxes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showsSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
            }
        }
    }

    private var selection: Binding<SidebarSelection?> {
        Binding(get: { model.selection }, set: { new in
            guard let new else { return }
            // On iPhone, choosing a mailbox (again) shows its list.
            router.compactColumn = .content
            Task { await model.select(new) }
        })
    }

    private func folders(of account: MailAccountID) -> [SyncedFolder] {
        if let synced = model.sync.folders[account], !synced.isEmpty {
            return synced.filter { $0.role != "all" }
        }
        // Not connected on this device: the folders that hold stored mail.
        return (model.folders[account] ?? []).map { SyncedFolder(name: $0, path: [$0]) }
    }

    private func count(_ category: MailCategory) -> MailboxRow.Count? {
        let count = model.attention.count(category)
        switch category {
        case .focused: return count.unread > 0 ? .attention(count.unread) : nil
        case .promotions, .quarantine: return count.total > 0 ? .quiet(count.total) : nil
        case .transactions, .updates, .subscriptions: return count.unread > 0 ? .normal(count.unread) : nil
        }
    }

    private var draftCount: MailboxRow.Count? {
        let count = model.sending?.drafts.count ?? 0
        return count > 0 ? .quiet(count) : nil
    }

    private var outboxCount: MailboxRow.Count? {
        guard let sending = model.sending else { return nil }
        if !sending.needsAttention.isEmpty { return .attention(sending.needsAttention.count) }
        return sending.pending.isEmpty ? nil : .quiet(sending.pending.count)
    }
}

/// An account's name and how its sync is doing, in words.
private struct AccountHeader: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // An address would wrap mid-domain ("example.-com"): one line, shortened in the middle.
            Text(account.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status = model.syncStatus(account.id) {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(model.needsPassword(account.id) ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .textCase(nil)
                    .accessibilityIdentifier("syncStatus.\(account.address)")
            }
        }
    }
}

struct MailboxRow: View {
    enum Count {
        case attention(Int), normal(Int), quiet(Int)
        var value: Int { switch self { case .attention(let n), .normal(let n), .quiet(let n): n } }
    }

    let title: String
    let systemImage: String
    let count: Count?
    var tint: Color?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            if let count {
                Text("\(count.value)")
                    .font(.callout.monospacedDigit().weight(count.isAttention ? .semibold : .regular))
                    .foregroundStyle(count.isAttention ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension MailboxRow.Count {
    var isAttention: Bool { if case .attention = self { return true }; return false }
}

enum FolderLook {
    static func icon(_ role: String?) -> String {
        switch role {
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

/// A space's colour name (the Tasks board palette) as a colour.
enum SpaceColor {
    static func color(_ name: String) -> Color {
        switch name {
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "brown": .brown
        case "gray": .gray
        default: .blue
        }
    }
}

/// A one-line notice: an icon in its meaning colour and a sentence.
struct NoticeLine: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
