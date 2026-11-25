import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The conversations of the selected mailbox, newest first; while searching, the matching
/// messages, narrowed by the chips. Swipe right to mark read or unread; swipe left to archive
/// (all the way), trash or flag. Every action goes through the account's action journal and
/// can be undone (GKM-015).
struct MessageListScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session
    @Environment(MailRouter.self) private var router

    private var browser: MailBrowser { model.browser }

    private var searchText: Binding<String> {
        Binding(get: { browser.searchText }, set: { browser.typeSearch($0) })
    }

    private var selection: Binding<String?> {
        Binding(get: { browser.selectedRowID }, set: { id in Task { await browser.select(id) } })
    }

    var body: some View {
        List(selection: selection) {
            SearchChipsRow()
            if session.isCheckingFolder {
                NoticeLine(systemImage: "arrow.triangle.2.circlepath", tint: .secondary,
                           text: "Files changed the mail folder; reading it again…")
                    .selectionDisabled()
            }
            ForEach(browser.rows) { row in
                MessageRow(row: row,
                           showsAccount: model.accounts.count > 1,
                           accountName: model.accounts.first { $0.id == row.latest.account }?.displayName,
                           isPending: model.sync.replay[row.latest.account]?.status.pendingMessages.contains(row.latest.id) == true)
                    .tag(row.id)
                    .listRowBackground(row.id == browser.selectedRowID ? Theme.accent.opacity(0.22) : Theme.window)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { act(row.isUnread ? .markRead : .markUnread, row) } label: {
                            Label(row.isUnread ? "Read" : "Unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(Theme.accent)
                        .accessibilityIdentifier("swipeReadUnread")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if model.actions.isTrash(browser.scope) {
                            Button(role: .destructive) {
                                Task { await model.actions.requestDeletion(threads: [row.threadID], in: browser.scope) }
                            } label: { Label("Delete", systemImage: "trash.slash") }
                        } else {
                            Button { act(.archive, row) } label: { Label("Archive", systemImage: "archivebox") }
                                .tint(.indigo)
                            Button(role: .destructive) { act(.moveToTrash, row) } label: { Label("Trash", systemImage: "trash") }
                        }
                        Button { act(row.isFlagged ? .unflag : .flag, row) } label: {
                            Label(row.isFlagged ? "Unflag" : "Flag", systemImage: row.isFlagged ? "flag.slash" : "flag")
                        }
                        .tint(.orange)
                        .accessibilityIdentifier("swipeFlag")
                    }
                    .contextMenu { RowMenu(row: row) }
                    .onAppear {
                        if row.id == browser.rows.last?.id { Task { await browser.loadMore() } }
                    }
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay { emptyState }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search mail")
        .refreshable { await session.refreshNow() }
        .toolbar {
            // An empty status would still draw an empty bubble beside Compose, so it only joins
            // the bar when it has something to say.
            if !StatusLine.text(model: model, session: session).isEmpty {
                ToolbarItem(placement: .bottomBar) { StatusLine() }
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { router.compose(await model.composeNew()) }
                } label: { Image(systemName: "square.and.pencil") }
                .disabled(model.accounts.allSatisfy { $0.connection == nil })
                .accessibilityLabel("New Message")
                .accessibilityIdentifier("composeButton")
            }
        }
        .confirmationDialog("Delete permanently?", isPresented: deletionShown, titleVisibility: .visible,
                            presenting: model.actions.deletionToConfirm) { request in
            Button(request.count == 1 ? "Delete Message" : "Delete \(request.count) Messages", role: .destructive) {
                Task { await model.actions.confirmDeletion() }
            }
        } message: { _ in
            Text("They are removed from the provider’s Trash. The copy in your Mail folder stays until you remove it.")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isEmpty {
            ContentUnavailableView {
                Label("No mail yet", systemImage: "envelope.open")
            } description: {
                Text("Add an account. Mail keeps every message as a file you own, in On My \(DeviceWords.model) ▸ Mail in Files.")
            } actions: {
                Button("Add Account") { router.showsAddAccount = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("addAccountButton")
            }
        } else if browser.rows.isEmpty {
            QuietNote(browser.isSearching ? "No messages match." : browser.scope.category?.emptyNote ?? "No messages here.")
        }
    }

    private var deletionShown: Binding<Bool> {
        Binding(get: { model.actions.deletionToConfirm != nil }, set: { if !$0 { model.actions.deletionToConfirm = nil } })
    }

    private func act(_ action: MessageAction, _ row: ListRow) {
        Task { await model.actions.perform(action, threads: [row.threadID], in: browser.scope) }
    }

    private var title: String {
        switch model.selection {
        case .allMail: "All Mail"
        case .category(let category): category.title
        case .account: model.selectedAccount?.displayName ?? "Mail"
        case .folder(_, let name):
            model.sync.folders.values.joined().first { $0.name == name }.map { $0.role == "inbox" ? "Inbox" : $0.path.last ?? name } ?? name
        case .drafts: "Drafts"
        case .outbox: "Outbox"
        case .space(let id): model.spaces.space(id)?.name ?? "Space"
        case .attachments: "Attachments"
        case .senders: "Senders"
        case .cleanup: "Clean Up"
        }
    }
}

/// The chips, while the search field is active or a search or filter is on.
private struct SearchChipsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if isSearching || model.browser.isSearching {
            SearchChips()
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
    }
}

/// The long-press menu of a row: the same actions as the swipes, plus moving it to a folder.
private struct RowMenu: View {
    @Environment(AppModel.self) private var model
    let row: ListRow

    var body: some View {
        let scope = model.browser.scope
        Button(row.isUnread ? "Mark as Read" : "Mark as Unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge") {
            perform(row.isUnread ? .markRead : .markUnread)
        }
        Button(row.isFlagged ? "Unflag" : "Flag", systemImage: "flag") { perform(row.isFlagged ? .unflag : .flag) }
        Button("Archive", systemImage: "archivebox") { perform(.archive) }
        let targets = model.actions.moveTargets(account: row.latest.account)
        if !targets.isEmpty {
            Menu("Move to…", systemImage: "folder") {
                ForEach(targets, id: \.self) { folder in
                    Button(folder.role == "inbox" ? "Inbox" : folder.path.joined(separator: " / ")) {
                        perform(.move(to: folder.name, account: row.latest.account))
                    }
                }
            }
        }
        if !model.spaces.spaces.isEmpty {
            Menu("Add to Space", systemImage: "square.stack") {
                ForEach(model.spaces.spaces) { space in
                    Button(space.name) {
                        Task {
                            await model.spaces.add(threads: [row.threadID], to: space.id)
                            await model.browser.reload()
                        }
                    }
                }
            }
        }
        Divider()
        if model.actions.isTrash(scope) {
            Button("Delete Permanently…", systemImage: "trash.slash", role: .destructive) {
                Task { await model.actions.requestDeletion(threads: [row.threadID], in: scope) }
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { perform(.moveToTrash) }
        }
    }

    private func perform(_ action: MessageAction) {
        Task { await model.actions.perform(action, threads: [row.threadID], in: model.browser.scope) }
    }
}

/// One conversation (or message): sender, subject, snippet. Unread is a dot and a heavier
/// sender; flagged is a flag; the count says how many messages the conversation has.
struct MessageRow: View {
    let row: ListRow
    let showsAccount: Bool
    let accountName: String?
    /// A change made here has not reached the provider yet (GKM-015).
    var isPending = false

    private var summary: MessageSummary { row.latest }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(row.isUnread ? Theme.accent : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.from?.displayName ?? "Unknown sender")
                        .font(.body.weight(row.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if row.messageCount > 1 {
                        Text("\(row.messageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if isPending {
                        Image(systemName: "icloud.and.arrow.up").font(.caption).foregroundStyle(.secondary)
                    }
                    if row.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    if row.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    Text(MessageDate.short(summary.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(summary.subject?.isEmpty == false ? summary.subject! : "(No subject)")
                    .font(.subheadline.weight(row.isUnread ? .medium : .regular))
                    .lineLimit(1)
                if !summary.snippet.isEmpty {
                    Text(summary.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if showsAccount, let accountName {
                    Text(accountName).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("messageRow")
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if row.isUnread { parts.append("Unread") }
        if row.isFlagged { parts.append("Flagged") }
        parts.append("From \(summary.from?.displayName ?? "unknown sender")")
        parts.append(summary.subject ?? "No subject")
        if row.messageCount > 1 { parts.append("\(row.messageCount) messages") }
        if row.hasAttachments { parts.append("Has attachments") }
        parts.append(MessageDate.short(summary.date))
        return parts.joined(separator: ", ")
    }
}

/// The sync's state at the bottom of the list, in a few words.
private struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session

    var body: some View {
        Text(Self.text(model: model, session: session))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize() // the bar gives it too little room otherwise ("Up t…")
            .accessibilityIdentifier("statusLine")
    }

    static func text(model: AppModel, session: MobileSession) -> String {
        if session.storageNotice != nil { return "Paused: low storage" }
        let accounts = model.accounts.filter { $0.connection != nil }
        guard !accounts.isEmpty else { return model.totalCount > 0 ? "\(model.totalCount.formatted()) messages" : "" }
        let lines = accounts.compactMap { SyncStatusText.line(model.sync.progress[$0.id]) }
        if let busy = lines.first(where: { $0 != "Up to date" }) { return busy }
        return lines.isEmpty ? "" : "Up to date"
    }
}
