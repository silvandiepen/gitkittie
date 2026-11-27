import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The conversations of the selected mailbox, newest first; while searching, the matching
/// messages, narrowed by the chips. Swipe right to mark read or unread; swipe left to archive
/// (all the way), trash or flag. Every action goes through the account's action journal and
/// can be undone (GKM-015). Select (Edit mode) picks several, Select All every row of the view,
/// and the bottom bar acts on all of them at once (GKM-071).
struct MessageListScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session
    @Environment(MailRouter.self) private var router
    @State private var editMode = EditMode.inactive

    private var isEditing: Bool { editMode.isEditing }

    private var browser: MailBrowser { model.browser }

    private var searchText: Binding<String> {
        Binding(get: { browser.searchText }, set: { browser.typeSearch($0) })
    }

    /// One row opens it; in Edit mode the rows are ticked, and ticks may include rows not
    /// loaded yet (Select All takes the whole view by id).
    private var selection: Binding<Set<String>> {
        Binding(get: {
            isEditing ? browser.markedRowIDs : Set([browser.selectedRowID].compactMap { $0 })
        }, set: { ids in
            if isEditing {
                browser.markedRowIDs = ids
            } else {
                // The list clears its selection when the stack goes back from the reader, but
                // SwiftUI doesn't write that back into preferredCompactColumn, so the router kept
                // saying .detail on the list. Say what is shown (GKM-085; the mailboxes' twin is
                // GKM-080). The reader itself is pushed by the row this list selects.
                if ids.isEmpty, router.isCollapsed { router.compactColumn = .content }
                let id = ids.first { $0 != browser.selectedRowID } ?? ids.first
                Task { await browser.select(id) }
            }
        })
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
                           isPending: model.sync.replay[row.latest.account]?.status.pendingMessages.contains(row.latest.id) == true,
                           deletedAtProvider: ProviderDeletionText.short(row.latest, account: model.account(of: row.latest)))
                    .tag(row.id)
                    .listRowBackground(!isEditing && row.id == browser.selectedRowID ? Theme.accent.opacity(0.22) : Theme.window)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { act(row.isUnread ? .markRead : .markUnread, row) } label: {
                            Label(row.isUnread ? "Read" : "Unread", systemImage: row.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(Theme.accentFill)
                        .accessibilityIdentifier("swipeReadUnread")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if model.actions.isTrash(browser.scope) {
                            Button(role: .destructive) {
                                Task { await model.actions.requestDeletion(browser.targets(actingOn: row.id), in: browser.scope) }
                            } label: { Label("Delete", systemImage: "trash.slash") }
                        } else {
                            Button { act(.archive, row) } label: { Label("Archive", systemImage: "archivebox") }
                                .tint(.indigo)
                            Button(role: .destructive) { act(.moveToTrash, row) } label: { Label("Trash", systemImage: "trash") }
                        }
                        Button { act(row.isFlagged ? .unflag : .flag, row) } label: {
                            Label(row.isFlagged ? "Unflag" : "Flag", systemImage: row.isFlagged ? "flag.slash" : "flag")
                        }
                        // A darker orange than the system's: white on it is 5:1, not 2:1 (GKM-061).
                        .tint(Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255))
                        .accessibilityIdentifier("swipeFlag")
                    }
                    .contextMenu { if !isEditing { RowMenu(row: row) } }
                    .onAppear {
                        if row.id == browser.rows.last?.id { Task { await browser.loadMore() } }
                    }
            }
            if browser.isSearching, browser.server.isShown {
                ServerResultsSection()
            }
        }
        .listStyle(.plain)
        .themedList()
        .overlay { emptyState }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search mail")
        .refreshable { await session.refreshNow() }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode) { _, mode in if !mode.isEditing { browser.clearMarks() } }
        // A new view, search or chip ends the selection; so does an action that moved it away.
        .onChange(of: browser.listIdentity) { editMode = .inactive }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Select") {
                    withAnimation { editMode = isEditing ? .inactive : .active }
                }
                .disabled(!isEditing && browser.rows.isEmpty)
                .accessibilityIdentifier("selectButton")
            }
            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    if browser.markedRowIDs.isEmpty {
                        Button("Select All") { Task { await browser.selectAll() } }
                            .accessibilityIdentifier("selectAllButton")
                    } else {
                        Button("Deselect All") { browser.clearMarks() }
                            .accessibilityIdentifier("deselectAllButton")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    SelectionBar { editMode = .inactive }
                }
            } else {
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
        }
        .confirmationDialog(model.actions.trashToConfirm?.question ?? "", isPresented: trashShown, titleVisibility: .visible,
                            presenting: model.actions.trashToConfirm) { request in
            Button("Move to Trash", role: .destructive) {
                Task {
                    await model.actions.confirmTrash(request)
                    editMode = .inactive
                }
            }
            .accessibilityIdentifier("confirmTrashButton")
        } message: { _ in
            Text("Undo puts them all back.")
        }
        .confirmationDialog("Delete permanently?", isPresented: deletionShown, titleVisibility: .visible,
                            presenting: model.actions.deletionToConfirm) { request in
            Button(request.count == 1 ? "Delete Message" : "Delete \(request.count) Messages", role: .destructive) {
                Task { await model.actions.confirmDeletion(request) }
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
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("addAccountButton")
            }
        } else if browser.rows.isEmpty, !(browser.isSearching && browser.server.isShown) {
            QuietNote(browser.isSearching ? "No messages match." : browser.scope.category?.emptyNote ?? "No messages here.")
        }
    }

    private var trashShown: Binding<Bool> {
        Binding(get: { model.actions.trashToConfirm != nil }, set: { if !$0 { model.actions.trashToConfirm = nil } })
    }

    private var deletionShown: Binding<Bool> {
        Binding(get: { model.actions.deletionToConfirm != nil }, set: { if !$0 { model.actions.deletionToConfirm = nil } })
    }

    private func act(_ action: MessageAction, _ row: ListRow) {
        let targets = browser.targets(actingOn: row.id)
        Task {
            if action == .moveToTrash {
                await model.actions.trash(targets, in: browser.scope)
            } else {
                await model.actions.perform(action, targets: targets, in: browser.scope)
            }
        }
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
        if let sender = row.latest.from, !sender.address.isEmpty {
            let name = SenderText.name(sender)
            Button("See All Mail from \(name)", systemImage: "person.crop.circle") {
                Task { await model.showAllMail(from: sender) }
            }
            // Blocking this sender in the row's account (GKM-072): a preview, then Apply.
            if let rule = model.senders.blockingRule(for: sender.address, account: row.latest.account) {
                Button(SenderRuleText.unblockMenuTitle(rule, name: name), systemImage: "hand.raised.slash") {
                    Task { await model.senders.proposeRemoval(of: rule) }
                }
            } else {
                Menu("Block \(name)", systemImage: "hand.raised") {
                    ForEach(SenderRuleText.blockActions, id: \.self) { action in
                        Button(SenderRuleText.blockMenuTitle(action, name: name),
                               systemImage: action == .alwaysJunk ? "xmark.bin" : "trash") {
                            Task { await model.senders.proposeBlock(action, address: sender, account: row.latest.account) }
                        }
                    }
                }
            }
            Divider()
        }
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
        TaskMenuItems(messageID: row.latest.id)
        Divider()
        if model.actions.isTrash(scope) {
            Button("Delete Permanently…", systemImage: "trash.slash", role: .destructive) {
                Task { await model.actions.requestDeletion(model.browser.targets(actingOn: row.id), in: scope) }
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                Task { await model.actions.trash(model.browser.targets(actingOn: row.id), in: scope) }
            }
        }
    }

    private func perform(_ action: MessageAction) {
        Task { await model.actions.perform(action, targets: model.browser.targets(actingOn: row.id), in: model.browser.scope) }
    }
}

/// The bottom bar in Edit mode: what is selected and what can be done to all of it at once, in
/// one step and one Undo (GKM-071). `done` leaves Edit mode after the rows moved away.
private struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    var body: some View {
        let browser = model.browser
        let targets = browser.targets(actingOn: nil)
        let scope = browser.scope
        let none = targets.isEmpty
        Menu {
            Button("Mark as Read", systemImage: "envelope.open") { act(.markRead) }
            Button("Mark as Unread", systemImage: "envelope.badge") { act(.markUnread) }
            Button("Flag", systemImage: "flag") { act(.flag) }
            Button("Unflag", systemImage: "flag.slash") { act(.unflag) }
        } label: {
            Label("Mark", systemImage: "envelope.badge")
        }
        .disabled(none)
        .accessibilityIdentifier("selectionMark")
        Menu {
            ForEach(moveAccounts(targets), id: \.self) { account in
                Section(model.accounts.first { $0.id == account }?.displayName ?? account.rawValue) {
                    ForEach(model.actions.moveTargets(account: account), id: \.self) { folder in
                        Button(folder.role == "inbox" ? "Inbox" : folder.path.joined(separator: " / ")) {
                            act(.move(to: folder.name, account: account))
                        }
                    }
                }
            }
        } label: {
            Label("Move", systemImage: "folder")
        }
        .disabled(none)
        Spacer()
        Text(none ? "Select messages" : browser.selectionTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityIdentifier("selectionCount")
        Spacer()
        Button { act(.archive) } label: { Label("Archive", systemImage: "archivebox") }
            .disabled(none || model.actions.isTrash(scope))
            .accessibilityIdentifier("selectionArchive")
        Button(role: .destructive) {
            Task {
                await model.actions.trash(targets, in: scope)
                if model.actions.trashToConfirm == nil, model.actions.deletionToConfirm == nil { done() }
            }
        } label: {
            Label(model.actions.isTrash(scope) ? "Delete" : "Trash", systemImage: "trash")
        }
        .disabled(none)
        .accessibilityIdentifier("selectionTrash")
    }

    /// The accounts whose folders a selection can move to: those of the loaded rows, or every
    /// account while some ticked rows are not loaded.
    private func moveAccounts(_ targets: ActionTargets) -> [MailAccountID] {
        let loaded = model.browser.loadedRows(of: targets)
        let accounts = loaded.count == targets.count ? Set(loaded.map(\.latest.account)) : Set(model.accounts.map(\.id))
        return accounts.filter { !model.actions.moveTargets(account: $0).isEmpty }.sorted { $0.rawValue < $1.rawValue }
    }

    private func act(_ action: MessageAction) {
        let targets = model.browser.targets(actingOn: nil)
        let scope = model.browser.scope
        Task {
            await model.actions.perform(action, targets: targets, in: scope)
            if action.changesLocation { done() }
        }
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
    /// "Deleted at iCloud": the provider deleted it; the copy here is kept (MAIL-075).
    var deletedAtProvider: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 9

    private var summary: MessageSummary { row.latest }
    /// At the accessibility text sizes the date and the marks go under the sender, and nothing
    /// is cut to one line (GKM-061).
    private var isLarge: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(row.isUnread ? Theme.accent : .clear)
                .frame(width: dot, height: dot)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                let header = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                     : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                header {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.from?.displayName ?? "Unknown sender")
                            .font(.body.weight(row.isUnread ? .semibold : .regular))
                            .lineLimit(isLarge ? 3 : 1)
                        if row.messageCount > 1 {
                            Text("\(row.messageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if !isLarge { Spacer(minLength: 6) }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if isPending {
                            Image(systemName: "icloud.and.arrow.up").font(.caption).foregroundStyle(.secondary)
                        }
                        if row.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                        if row.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                        Text(MessageDate.short(summary.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary.subject?.isEmpty == false ? summary.subject! : "(No subject)")
                    .font(.subheadline.weight(row.isUnread ? .medium : .regular))
                    .lineLimit(isLarge ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isLarge)
                if !summary.snippet.isEmpty {
                    // The snippet is short (200 characters at most, MailIndex.snippet); at the accessibility
                    // sizes it is shown whole rather than cut.
                    Text(summary.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(isLarge ? nil : 2)
                        .fixedSize(horizontal: false, vertical: isLarge)
                }
                if let deletedAtProvider {
                    Label(deletedAtProvider, systemImage: "trash.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isLarge ? nil : 1)
                }
                if showsAccount, let accountName {
                    Text(accountName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        // One element; its swipe actions and long-press menu are VoiceOver actions (SwiftUI
        // adds them to the row).
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
        if isPending { parts.append("Change waiting to sync") }
        if let deletedAtProvider { parts.append(deletedAtProvider) }
        parts.append(MessageDate.short(summary.date))
        if !summary.snippet.isEmpty { parts.append(summary.snippet) }
        if showsAccount, let accountName { parts.append(accountName) }
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
            // A live line: VoiceOver reads it as it changes, under a name that says what it is.
            .accessibilityLabel("Sync")
            .accessibilityValue(Self.text(model: model, session: session))
            .accessibilityAddTraits(.updatesFrequently)
            // The bar keeps its text small at the largest sizes; a long press shows it large.
            .accessibilityShowsLargeContentViewer()
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
