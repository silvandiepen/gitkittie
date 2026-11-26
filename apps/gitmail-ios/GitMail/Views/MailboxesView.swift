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
                    MailboxRow(title: category.title, systemImage: category.systemImage, count: count(category),
                               countMeaning: countMeaning(category))
                        .tag(SidebarSelection.category(category))
                }
                MailboxRow(title: "All Mail", systemImage: "tray.full", count: nil)
                    .tag(SidebarSelection.allMail)
                if model.attention.pendingClassification > 0 {
                    Text("Sorting \(model.attention.pendingClassification.formatted()) messages…")
                        .font(.caption).foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            Section {
                MailboxRow(title: "Drafts", systemImage: "doc", count: draftCount, countMeaning: { $0 == 1 ? "1 draft" : "\($0) drafts" })
                    .tag(SidebarSelection.drafts)
                MailboxRow(title: "Outbox", systemImage: "tray.and.arrow.up", count: outboxCount, countMeaning: outboxMeaning)
                    .tag(SidebarSelection.outbox)
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
                    MailboxRow(title: "All of \(account.displayName)", systemImage: "person.crop.circle", count: nil,
                               shortensInMiddle: true)
                        .tag(SidebarSelection.account(account.id))
                    ForEach(folders(of: account), id: \.self) { folder in
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
        Binding(get: {
            // Back on Mailboxes on iPhone nothing is chosen, as in Mail: choosing the mailbox you
            // came from is then a change the list acts on (GKM-080). Side by side (iPad), the
            // chosen mailbox stays highlighted.
            router.showsMailboxesAlone ? nil : model.selection
        }, set: { new in
            guard let new else {
                // The list clears its selection when the stack goes back to Mailboxes, but SwiftUI
                // doesn't write that back into preferredCompactColumn: without this the router
                // still says .content, and choosing the same mailbox changes nothing (GKM-080).
                // Side by side, a cleared selection means nothing; the mailbox stays chosen.
                if router.isCollapsed { router.compactColumn = .sidebar }
                return
            }
            // On iPhone, choosing a mailbox (again) shows its list.
            router.compactColumn = .content
            router.mailboxChoices += 1
            Task { await model.select(new) }
        })
    }

    /// The folders the account shows, in its order (Settings ▸ the account ▸ Mailboxes,
    /// MAIL-093), without All Mail.
    private func folders(of account: MailAccount) -> [SyncedFolder] {
        model.sidebarFolders(of: account).filter { $0.role != "all" }
    }

    private func count(_ category: MailCategory) -> MailboxRow.Count? {
        let count = model.attention.count(category)
        switch category {
        case .focused: return count.unread > 0 ? .attention(count.unread) : nil
        case .promotions, .quarantine: return count.total > 0 ? .quiet(count.total) : nil
        case .transactions, .updates, .subscriptions: return count.unread > 0 ? .normal(count.unread) : nil
        }
    }

    private func countMeaning(_ category: MailCategory) -> (Int) -> String {
        switch category {
        case .promotions, .quarantine: { $0 == 1 ? "1 message" : "\($0) messages" }
        default: { "\($0) unread" }
        }
    }

    private var outboxMeaning: (Int) -> String {
        guard let sending = model.sending, !sending.needsAttention.isEmpty else { return { "\($0) waiting" } }
        return { "\($0) need attention" }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let account: MailAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // An address would wrap mid-domain ("example.-com"): one line, shortened in the middle.
            Text(account.displayName)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
            if let status = model.syncStatus(account.id) {
                Text(status)
                    .font(.caption2)
                    // A fixed colour: a hierarchical .secondary inside the already-secondary
                    // header came out at about 2:1 (GKM-061).
                    .foregroundStyle(model.needsPassword(account.id) ? AnyShapeStyle(.orange) : AnyShapeStyle(Color(uiColor: .secondaryLabel)))
                    .textCase(nil)
                    .accessibilityIdentifier("syncStatus.\(account.address)")
            }
        }
        // The account and how its sync is doing, read together.
        .accessibilityElement(children: .combine)
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
    /// What the number counts, for VoiceOver: "3 unread", "12 messages".
    var countMeaning: (Int) -> String = { "\($0) unread" }
    /// For a name that is often an address: shortened in the middle rather than wrapped
    /// mid-domain ("example.-com") in the iPad sidebar (GKM-064), like the account's header.
    var shortensInMiddle = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // At the accessibility sizes the icon and the count go above the name, so the name
                // has the column's whole width: beside a scaled icon, the iPad sidebar broke even
                // "Focused" in the middle of the word (GKM-064).
                VStack(alignment: .leading, spacing: 4) {
                    HStack { icon; Spacer(minLength: 8); countText }
                    name
                }
            } else {
                HStack(spacing: 12) {
                    icon
                    name
                    Spacer(minLength: 8)
                    countText
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(count.map { countMeaning($0.value) } ?? "")
        .accessibilityIdentifier("mailbox.\(title)")
    }
}

private extension MailboxRow {
    var icon: some View {
        Image(systemName: systemImage)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .frame(width: iconWidth)
            .accessibilityHidden(true)
    }

    /// A long folder or space name wraps at the accessibility sizes instead of vanishing.
    @ViewBuilder var name: some View {
        if shortensInMiddle {
            Text(title)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
        } else {
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder var countText: some View {
        if let count {
            Text("\(count.value)")
                .font(.callout.monospacedDigit().weight(count.isAttention ? .semibold : .regular))
                .foregroundStyle(count.isAttention ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
        }
    }
}

private extension MailboxRow.Count {
    var isAttention: Bool { if case .attention = self { return true }; return false }
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
        .accessibilityElement(children: .combine)
        .fixedSize(horizontal: false, vertical: true)
    }
}
