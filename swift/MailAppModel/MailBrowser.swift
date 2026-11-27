import Foundation
import MailClassifier
import MailCore
import MailReader
import MailStore
import MailSync
import Observation

/// Which mail the list shows, from the sidebar.
enum MailScope: Hashable {
    case allMail
    case account(MailAccountID)
    case folder(MailAccountID, String)
    /// Focused, Transactions, … across every account (GKM-018).
    case category(MailCategory)
    /// A space's messages, across accounts (GKM-022).
    case space(MailSpaceID)

    var account: MailAccountID? {
        switch self {
        case .allMail, .category, .space: nil
        case .account(let id), .folder(let id, _): id
        }
    }

    var space: MailSpaceID? {
        if case .space(let id) = self { return id }
        return nil
    }

    var folder: String? {
        if case .folder(_, let name) = self { return name }
        return nil
    }

    var category: MailCategory? {
        if case .category(let category) = self { return category }
        return nil
    }
}

/// The date filter chip.
enum DateFilter: String, CaseIterable, Identifiable {
    case any, today, week, month, year
    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any Time"
        case .today: "Today"
        case .week: "Past Week"
        case .month: "Past Month"
        case .year: "Past Year"
        }
    }

    /// The instant the period starts, in the user's calendar.
    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .any: nil
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .month, value: -1, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

/// The filter chips under the search field (GKM-016). Combined with whatever the search text
/// says (`from:`, `is:unread`, …): both narrow, neither widens.
struct SearchFilters: Equatable {
    var account: MailAccountID?
    var participant = ""
    var date = DateFilter.any
    var hasAttachment = false
    var folder: String?
    var unreadOnly = false
    var flaggedOnly = false
    /// The category chip (GKM-018).
    var category: MailCategory?
    /// The From chip: exactly this sender's address, from "See All Mail from…" (GKM-071).
    var sender: MailAddress?

    var isEmpty: Bool { self == SearchFilters() }
}

/// One row of the message list: a conversation, or (while searching) a single message.
enum ListRow: Identifiable, Hashable {
    case thread(ThreadSummary)
    case message(MessageSummary)

    var id: String {
        switch self {
        case .thread(let thread): "t:" + thread.id
        case .message(let message): Self.id(of: message.id)
        }
    }

    /// The id of a message's row while searching.
    static func id(of message: MailMessageID) -> String { "m:" + message.rawValue }

    var latest: MessageSummary {
        switch self {
        case .thread(let thread): thread.latest
        case .message(let message): message
        }
    }

    var threadID: String { latest.threadID }
    var messageCount: Int { if case .thread(let thread) = self { return thread.messageCount }; return 1 }
    var isUnread: Bool {
        switch self {
        case .thread(let thread): thread.unreadCount > 0
        case .message(let message): message.isUnread
        }
    }
    var isFlagged: Bool {
        switch self {
        case .thread(let thread): thread.isFlagged
        case .message(let message): message.isFlagged
        }
    }
    var hasAttachments: Bool {
        switch self {
        case .thread(let thread): thread.hasAttachments
        case .message(let message): message.hasAttachments
        }
    }

    /// Takes the read and flag marks of the open conversation, for a row kept in the list after
    /// a change took it out of the query.
    mutating func reflect(_ open: OpenThread) {
        switch self {
        case .thread(var thread):
            thread.unreadCount = open.messages.filter(\.summary.isUnread).count
            thread.isFlagged = open.messages.contains(where: \.summary.isFlagged)
            if let latest = open.messages.first(where: { $0.id == thread.latest.id }) { thread.latest = latest.summary }
            self = .thread(thread)
        case .message(let message):
            if let shown = open.messages.first(where: { $0.id == message.id }) { self = .message(shown.summary) }
        }
    }
}

/// One message in the open conversation.
struct ThreadMessage: Identifiable {
    var id: MailMessageID { summary.id }
    var summary: MessageSummary
    var isExpanded: Bool
    /// Loaded when the message is expanded.
    var stored: StoredMessage?
    var content: ReaderContent?
    /// Remote images are loaded for this message (the user chose to, for it or its sender).
    var remoteImagesLoaded = false
    var showsPlainText = false
    var loadError: String?
    /// Why the classifier put it where it is (GKM-017); nil until classified.
    var verdict: StoredVerdict?
}

/// The open conversation: its messages oldest first, the newest (or the search hit) expanded.
struct OpenThread {
    var id: String
    var messages: [ThreadMessage]
    var subject: String? { messages.last?.summary.subject }
}

/// The message list, the open thread and search (GKM-012, GKM-016). UI-free: it turns what the
/// store holds into what the list and reader show; views render it and send intents back.
@MainActor
@Observable
final class MailBrowser {
    static let pageSize = 200

    private(set) var scope = MailScope.allMail
    private(set) var searchText = ""
    private(set) var filters = SearchFilters()
    private(set) var rows: [ListRow] = []
    private(set) var canLoadMore = false
    private(set) var selectedRowID: String?
    /// Rows picked with ⌘-click or ⇧-click besides the selected one, for acting on several
    /// conversations at once (MailBrowser+Marking.swift).
    var markedRowIDs: Set<String> = []
    private(set) var openThread: OpenThread? {
        didSet { if oldValue?.id != openThread?.id { onOpenThreadChanged?() } }
    }
    /// Called when another conversation opens or the reader closes: the app model remembers
    /// where the window is (MAIL-107).
    @ObservationIgnored var onOpenThreadChanged: (@MainActor () -> Void)?
    /// An error from the last action, shown once.
    var actionError: String?
    /// Called when a read or flag change was queued for the provider (GKM-015).
    @ObservationIgnored var onActionsQueued: (@MainActor ([MailAccountID]) async -> Void)?
    /// Messages shown expanded in the reader: the sender's local open history (GKM-019).
    @ObservationIgnored var onMessagesOpened: (@MainActor ([MailMessageID]) async -> Void)?
    /// Fetches an attachment a partial message left at the provider (GKM-036): the account's
    /// on-demand fetcher, set by the app model.
    @ObservationIgnored var onFetchAttachment: (@MainActor (AttachmentReference, MailMessageID) async throws -> AttachmentReference)?
    /// Attachments downloading now, by ``downloadKey(_:of:)``, for the reader's progress.
    private(set) var downloading: Set<String> = []
    /// Mail at the provider that matches the search and is not downloaded (GKM-041).
    private(set) var server = ServerSearchState.off
    /// The hit being downloaded to open it, by id.
    private(set) var openingServerHit: String?
    /// The accounts' sync, which searches their providers; set by the app model.
    @ObservationIgnored weak var sync: AccountSync?
    /// How long typing must pause before the server is asked (MAIL-082). Zero in tests.
    @ObservationIgnored var serverSearchDelay: Duration = .milliseconds(600)
    @ObservationIgnored private var serverQuery: ServerQuery?
    @ObservationIgnored private var serverTask: Task<Void, Never>?

    @ObservationIgnored private(set) var store: MailStore?
    private var preferences: RemoteContentPreferences?
    private var quickLookFolder: URL?
    private var generation = 0
    /// What the loaded list shows; a change of view, search or chips ends a selection of many.
    @ObservationIgnored private var loadedList: ListIdentity?
    /// Injected for tests; the user's calendar and clock otherwise.
    var calendar = Calendar.current
    var now: () -> Date = Date.init

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty
    }

    func attach(_ store: MailStore) {
        self.store = store
        preferences = RemoteContentPreferences(deviceFolder: store.locations.deviceFolder)
        quickLookFolder = store.locations.deviceFolder.appendingPathComponent("cache/quicklook", isDirectory: true)
        if let quickLookFolder { try? FileManager.default.removeItem(at: quickLookFolder) }
    }

    // MARK: Intents: the list

    func setScope(_ scope: MailScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        await reload()
    }

    func search(_ text: String) async {
        guard text != searchText else { return }
        searchText = text
        await reload()
    }

    /// For a search field's binding: keeps the text at once and runs the query after. A text
    /// field reads its text back on the next render; if the text only changed inside a later
    /// task, the field would get the old text back and lose what was just typed. Quick typing
    /// starts overlapping reloads; the generation check keeps only the newest result.
    @discardableResult
    func typeSearch(_ text: String) -> Task<Void, Never>? {
        guard text != searchText else { return nil }
        searchText = text
        return Task { await reload() }
    }

    func setFilters(_ filters: SearchFilters) async {
        guard filters != self.filters else { return }
        self.filters = filters
        await reload()
    }

    /// Back to the plain list of the scope: no search text, no chips.
    func clearSearch() async {
        guard isSearching else { return }
        searchText = ""
        filters = SearchFilters()
        await reload()
    }

    /// "See All Mail from…" (GKM-071): one sender's mail, the search cleared and the From chip
    /// set. The view (All Mail) is the app model's to choose.
    func showSender(_ sender: MailAddress) async {
        searchText = ""
        filters = SearchFilters(sender: sender)
        await reload()
    }

    /// The query the list runs: the scope, then the search text's own syntax, then the chips.
    var query: SearchQuery {
        var query = SearchQuery.parse(searchText, calendar: calendar)
        query.account = filters.account ?? query.account ?? scope.account
        query.mailbox = filters.folder ?? query.mailbox ?? scope.folder
        query.space = scope.space
        let participant = filters.participant.trimmingCharacters(in: .whitespaces)
        if !participant.isEmpty { query.participant = [query.participant, participant].compactMap { $0 }.joined(separator: " ") }
        if let start = filters.date.start(now: now(), calendar: calendar) { query.after = max(query.after ?? start, start) }
        query.hasAttachment = query.hasAttachment || filters.hasAttachment
        query.unreadOnly = query.unreadOnly || filters.unreadOnly
        query.flaggedOnly = query.flaggedOnly || filters.flaggedOnly
        query.category = filters.category ?? query.category ?? scope.category
        query.sender = filters.sender?.address
        return query
    }

    /// The view, search text and chips: what a selection of many belongs to.
    struct ListIdentity: Equatable {
        var scope: MailScope
        var searchText: String
        var filters: SearchFilters
    }

    var listIdentity: ListIdentity { ListIdentity(scope: scope, searchText: searchText, filters: filters) }

    /// Reloads the first page. Keeps the selection when it is still in the list. With
    /// `keepingPlace` (after an action took rows out), as many rows as were loaded, so the list
    /// stays where it was instead of going back to its first page (GKM-071). The same when the
    /// selected row is below the first page (GKM-085): a refresh (the open conversation marked
    /// read, a sync) dropped it, and with it the selection and the open conversation.
    func reload(keepingPlace: Bool = false) async {
        guard let store else { return }
        generation += 1
        let mine = generation
        let identity = listIdentity
        let sameList = loadedList == identity
        if !sameList {
            loadedList = identity
            clearMarks()
        }
        let selectedIndex = selectedRowID.flatMap { id in rows.firstIndex { $0.id == id } }
        let keepsSelection = sameList && (selectedIndex ?? 0) >= Self.pageSize
        do {
            let count = keepingPlace || keepsSelection ? max(rows.count, Self.pageSize) : Self.pageSize
            let found = try await page(from: store, offset: 0, limit: count)
            guard mine == generation else { return } // a newer query landed meanwhile
            rows = found
            canLoadMore = found.count == count
            if let selected = selectedRowID, !rows.contains(where: { $0.id == selected }) {
                selectedRowID = nil
                openThread = nil
            }
            // A row that left the view (trashed, moved, archived) leaves the marks with it, so
            // the next action never reaches mail no longer shown (GKM-075). Marks may include
            // rows not loaded yet (Select All, GKM-071): those are checked against the view's ids.
            let shown = Set(rows.map(\.id))
            if !markedRowIDs.isSubset(of: shown) {
                let inView = try await viewRowIDs(from: store)
                guard mine == generation else { return }
                markedRowIDs.formIntersection(Set(inView))
            }
            updateServerSearch()
        } catch {
            actionError = String(describing: error)
        }
    }

    func loadMore() async {
        guard let store, canLoadMore else { return }
        let mine = generation
        do {
            let more = try await page(from: store, offset: rows.count, limit: Self.pageSize)
            guard mine == generation else { return }
            rows += more
            canLoadMore = more.count == Self.pageSize
        } catch {
            actionError = String(describing: error)
        }
    }

    /// The id of every row the view has, loaded or not, in the list's order: what Select All
    /// takes (GKM-071). Ids only, so thousands load no rows.
    func viewRowIDs(from store: MailStore) async throws -> [String] {
        let query = query
        if isSearching { return try await store.messageIDs(query).map(ListRow.id(of:)) }
        return try await store.threadIDs(query).map { "t:" + $0 }
    }

    private func page(from store: MailStore, offset: Int, limit: Int) async throws -> [ListRow] {
        let query = query
        if isSearching {
            return try await store.search(query, limit: limit, offset: offset).map(ListRow.message)
        }
        return try await store.threads(query, limit: limit, offset: offset).map(ListRow.thread)
    }

    // MARK: Searching the server (GKM-041)

    /// The provider's half of the search, or nil when there is none.
    var currentServerQuery: ServerQuery? {
        guard isSearching else { return nil }
        let explicitCategory = filters.category ?? SearchQuery.parse(searchText, calendar: calendar).category
        return ServerQuery.make(query, explicitCategory: explicitCategory)
    }

    /// Starts, keeps or ends the server search for the current query, after the local results
    /// are in. A new query cancels the one running; an unchanged one is not asked again (the
    /// list reloads whenever the sync stores mail), except to retry after being offline or to
    /// start once an account has mail left at the provider. Waits ``serverSearchDelay`` first,
    /// so typing asks the server once, not per letter.
    func updateServerSearch() {
        let next = currentServerQuery
        guard next != serverQuery || server == .off || server == .offline else { return }
        serverTask?.cancel()
        serverTask = nil
        serverQuery = next
        guard let next, let sync, sync.leavesMailOnServer(account: next.account) else {
            server = .off
            return
        }
        if let reason = next.unavailable {
            server = .unavailable(reason)
            return
        }
        if sync.isOffline(account: next.account) {
            server = .offline
            return
        }
        server = .searching
        let delay = serverSearchDelay
        serverTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let sync = self?.sync, !Task.isCancelled else { return }
            let state = await sync.searchServer(next)
            guard let self, !Task.isCancelled, self.serverQuery == next else { return }
            self.server = state
        }
    }

    /// Downloads a message found on the server, stores it like synced mail and opens it. It is
    /// then one of the local results; offline or gone from the provider, ``actionError`` says so.
    func openServerHit(_ hit: ServerSearchHit) async {
        guard let sync, openingServerHit == nil else { return }
        openingServerHit = hit.id
        defer { openingServerHit = nil }
        do {
            let id = try await sync.downloadServerHit(hit)
            if case .found(var hits, let total) = server {
                hits.removeAll { $0.id == hit.id }
                server = .found(hits, total: max(hits.count, total - 1))
            }
            await reload()
            let rowID = ListRow.id(of: id)
            if rows.contains(where: { $0.id == rowID }) {
                await select(rowID)
            } else if let summary = try await store?.summary(of: id) {
                await show(id, threadID: summary.threadID)
            }
        } catch let failure as ServerSearcher.Failure {
            actionError = failure.description
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Intents: selection and keyboard

    func select(_ rowID: String?) async {
        guard rowID != selectedRowID || openThread == nil else { return }
        selectedRowID = rowID
        guard let rowID, let row = rows.first(where: { $0.id == rowID }) else { openThread = nil; return }
        await open(row)
    }

    /// Opens a message's conversation in the reader without changing the list: the attachment
    /// library's "Show Message" (GKM-023).
    func show(_ message: MailMessageID, threadID: String) async {
        guard let store else { return }
        do {
            let summaries = try await store.thread(threadID)
            var thread = OpenThread(id: threadID, messages: summaries.map { ThreadMessage(summary: $0, isExpanded: $0.id == message) })
            for index in thread.messages.indices where thread.messages[index].isExpanded {
                thread.messages[index] = await loaded(thread.messages[index], store: store)
            }
            selectedRowID = rows.first { $0.threadID == threadID }?.id
            openThread = thread
        } catch {
            actionError = String(describing: error)
        }
    }

    func selectNext() async { await move(by: 1) }
    func selectPrevious() async { await move(by: -1) }

    private func move(by step: Int) async {
        guard !rows.isEmpty else { return }
        let current = selectedRowID.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        await select(rows[next].id)
        if next >= rows.count - 20 { await loadMore() }
    }

    // MARK: The open thread

    /// Opens a message from its notification (GKM-037): its conversation, selected in the list
    /// when the list shows it, with that message expanded and read, as if it had been chosen.
    func reveal(_ message: MailMessageID, threadID: String) async {
        await loadRows(upTo: threadID)
        await openSelecting(threadID, focus: message)
    }

    /// Opens a conversation again where the window was left (MAIL-107): only when the view
    /// still holds it (not deleted, not moved out of it), selected in the list, its row loaded
    /// like a notification's when it is below the first page (GKM-112). Opening it marks it
    /// read, as choosing it does (MAIL-073, MAIL-108).
    @discardableResult
    func reopen(_ threadID: String) async -> Bool {
        guard !isSearching, await loadRows(upTo: threadID) else { return false }
        await openSelecting(threadID, focus: nil)
        return openThread?.id == threadID
    }

    /// Selects the conversation's row when the list has it and opens the conversation.
    private func openSelecting(_ threadID: String, focus: MailMessageID?) async {
        selectedRowID = rows.first { $0.threadID == threadID }?.id
        await openThread(threadID, focus: focus, rowID: selectedRowID)
    }

    /// Loads pages of the list until it has the conversation's row, when the view holds it below
    /// the pages loaded so far (GKM-085). Without a row nothing is selected, and on iPhone the
    /// reader is pushed by the list's selection: a notification for an older conversation, or
    /// the one the app was left on (GKM-112), opened the list and not the conversation.
    /// Returns whether the view holds the conversation.
    @discardableResult
    private func loadRows(upTo threadID: String) async -> Bool {
        guard !rows.contains(where: { $0.threadID == threadID }) else { return true }
        guard let store, !isSearching, (try? await store.threadIDs(query))?.contains(threadID) == true else { return false }
        while canLoadMore, !rows.contains(where: { $0.threadID == threadID }) {
            let loaded = rows.count
            await loadMore()
            // The view changed meanwhile, or a page failed: stop rather than ask again.
            if rows.count == loaded { break }
        }
        return true
    }

    private func open(_ row: ListRow) async {
        // Newest expanded; while searching, the hit itself.
        let hit: MailMessageID? = if case .message(let hit) = row { hit.id } else { nil }
        await openThread(row.threadID, focus: hit, rowID: row.id)
    }

    /// Opens a conversation with `focus` expanded (the newest message when nil or not in it),
    /// unless the selection moved on to `rowID`'s successor meanwhile.
    private func openThread(_ threadID: String, focus wanted: MailMessageID?, rowID: String?) async {
        guard let store else { return }
        do {
            let summaries = try await store.thread(threadID)
            guard selectedRowID == rowID else { return }
            let focus = summaries.contains { $0.id == wanted } ? wanted : summaries.last?.id
            var thread = OpenThread(id: threadID, messages: summaries.map { ThreadMessage(summary: $0, isExpanded: $0.id == focus) })
            for index in thread.messages.indices where thread.messages[index].isExpanded {
                thread.messages[index] = await loaded(thread.messages[index], store: store)
            }
            guard selectedRowID == rowID else { return }
            openThread = thread
            await onMessagesOpened?(thread.messages.filter(\.isExpanded).map(\.id))
            await markRead(thread.messages.filter { $0.summary.isUnread }.map(\.id))
        } catch {
            actionError = String(describing: error)
        }
    }

    func toggleExpanded(_ id: MailMessageID) async {
        guard let store, var thread = openThread, let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
        thread.messages[index].isExpanded.toggle()
        if thread.messages[index].isExpanded, thread.messages[index].content == nil {
            thread.messages[index] = await loaded(thread.messages[index], store: store)
        }
        if openThread?.id == thread.id { openThread = thread }
    }

    private func loaded(_ message: ThreadMessage, store: MailStore) async -> ThreadMessage {
        var message = message
        do {
            let stored = try await store.message(message.id)
            let sender = SenderAssessment.assess(from: stored.front.from, replyTo: stored.front.replyTo)
            var allowed = message.remoteImagesLoaded
            // A per-sender choice never applies to a message whose sender looks spoofed.
            if !allowed, sender.warnings.isEmpty, let address = sender.address, let preferences {
                allowed = await preferences.allowsRemoteImages(from: address)
            }
            message.stored = stored
            message.verdict = try await store.verdict(of: message.id)
            message.remoteImagesLoaded = allowed
            message.content = ReaderContent.make(from: stored, allowRemoteImages: allowed, preferPlainText: message.showsPlainText)
            message.loadError = nil
        } catch {
            message.loadError = String(describing: error)
        }
        return message
    }

    /// "Load remote images": for this message only, or always for its sender.
    func loadRemoteImages(for id: MailMessageID, alwaysForSender: Bool) async {
        guard let store, var thread = openThread, let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
        if alwaysForSender, let address = thread.messages[index].content?.sender.address, let preferences {
            do { try await preferences.setAllowsRemoteImages(true, from: address) } catch { actionError = String(describing: error) }
        }
        thread.messages[index].remoteImagesLoaded = true
        thread.messages[index] = await loaded(thread.messages[index], store: store)
        if openThread?.id == thread.id { openThread = thread }
    }

    /// Stops loading remote images for a sender (and hides them again here).
    func blockRemoteImages(for id: MailMessageID) async {
        guard let store, var thread = openThread, let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
        if let address = thread.messages[index].content?.sender.address, let preferences {
            do { try await preferences.setAllowsRemoteImages(false, from: address) } catch { actionError = String(describing: error) }
        }
        thread.messages[index].remoteImagesLoaded = false
        thread.messages[index] = await loaded(thread.messages[index], store: store)
        if openThread?.id == thread.id { openThread = thread }
    }

    func setShowsPlainText(_ plain: Bool, for id: MailMessageID) async {
        guard let store, var thread = openThread, let index = thread.messages.firstIndex(where: { $0.id == id }) else { return }
        thread.messages[index].showsPlainText = plain
        thread.messages[index] = await loaded(thread.messages[index], store: store)
        if openThread?.id == thread.id { openThread = thread }
    }

    func senderAllowsRemoteImages(_ address: String?) async -> Bool {
        guard let address, let preferences else { return false }
        return await preferences.allowsRemoteImages(from: address)
    }

    /// After a correction or a rule changed verdicts: the list (a message may have left this
    /// view) and the open messages' reasons.
    func refreshAfterClassificationChange() async {
        guard let store else { return }
        if var thread = openThread {
            do {
                for index in thread.messages.indices where thread.messages[index].stored != nil {
                    thread.messages[index].verdict = try await store.verdict(of: thread.messages[index].id)
                }
            } catch {
                actionError = String(describing: error)
            }
            if openThread?.id == thread.id { openThread = thread }
        }
        // A correction moves the message where you said: its row leaves this view at once.
        await refreshAfterFlagChange(keepsOpenRow: false)
    }

    // MARK: Flags

    func setUnread(_ unread: Bool, for id: MailMessageID) async {
        await updateFlags(of: id) { $0.seen = !unread }
    }

    func setFlagged(_ flagged: Bool, for id: MailMessageID) async {
        await updateFlags(of: id) { $0.flagged = flagged }
    }

    /// The selected row's newest message: what the Message menu acts on.
    var selectedMessage: MessageSummary? {
        if let thread = openThread { return thread.messages.last(where: \.isExpanded)?.summary ?? thread.messages.last?.summary }
        return selectedRowID.flatMap { id in rows.first { $0.id == id }?.latest }
    }

    private func markRead(_ ids: [MailMessageID]) async {
        guard !ids.isEmpty else { return }
        for id in ids { await updateFlags(of: id, refresh: false) { $0.seen = true } }
        await refreshAfterFlagChange()
    }

    private func updateFlags(of id: MailMessageID, refresh: Bool = true, _ change: (inout MessageFlags) -> Void) async {
        guard let store else { return }
        do {
            let before = try await store.flags(of: id)
            var flags = before
            change(&flags)
            // Through the action journal, so the provider gets it too (GKM-015).
            var changes: [MailChange] = []
            if flags.seen != before.seen { changes.append(MailChange(id, .setSeen(flags.seen))) }
            if flags.flagged != before.flagged { changes.append(MailChange(id, .setFlagged(flags.flagged))) }
            if let batch = try await store.perform(changes) { await onActionsQueued?(batch.accounts) }
            if var thread = openThread, let index = thread.messages.firstIndex(where: { $0.id == id }) {
                thread.messages[index].summary.isUnread = !flags.seen
                thread.messages[index].summary.isFlagged = flags.flagged
                openThread = thread
            }
            if refresh { await refreshAfterFlagChange() }
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Re-reads the loaded rows so unread and flag marks are current, without moving the list.
    /// The open row stays where it was even when the change takes it out of the list (an
    /// unread receipt in Focused, MAIL-076, or the Unread filter): it goes with the next reload.
    private func refreshAfterFlagChange(keepsOpenRow: Bool = true) async {
        guard let store else { return }
        do {
            let count = max(rows.count, Self.pageSize)
            let query = query
            var fresh: [ListRow] = isSearching
                ? try await store.search(query, limit: count).map(ListRow.message)
                : try await store.threads(query, limit: count).map(ListRow.thread)
            if keepsOpenRow, let selected = selectedRowID, !fresh.contains(where: { $0.id == selected }),
               let index = rows.firstIndex(where: { $0.id == selected }) {
                var kept = rows[index]
                if let thread = openThread, thread.id == kept.threadID { kept.reflect(thread) }
                fresh.insert(kept, at: min(index, fresh.count))
            }
            rows = fresh
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Attachments

    static func downloadKey(_ attachment: AttachmentReference, of message: MailMessageID) -> String {
        "\(message.rawValue)#\(attachment.section ?? attachment.blob)"
    }

    /// The attachment ready to read: as it is when downloaded; otherwise fetched once from the
    /// provider (progress in ``downloading``), and the open message re-read so the reader lists
    /// it as downloaded. Offline, it throws what the fetcher says ("You're offline…").
    func downloaded(_ attachment: AttachmentReference, of message: MailMessageID) async throws -> AttachmentReference {
        guard !attachment.isDownloaded else { return attachment }
        guard let onFetchAttachment else { throw MailStoreError.attachmentNotDownloaded(attachment.fileName) }
        let key = Self.downloadKey(attachment, of: message)
        downloading.insert(key)
        defer { downloading.remove(key) }
        let fetched = try await onFetchAttachment(attachment, message)
        await reloadMessage(message)
        return fetched
    }

    /// Re-reads one message of the open conversation (after a part was fetched or it was completed).
    func reloadMessage(_ id: MailMessageID) async {
        guard let store, var thread = openThread, let index = thread.messages.firstIndex(where: { $0.id == id }),
              thread.messages[index].content != nil else { return }
        thread.messages[index] = await loaded(thread.messages[index], store: store)
        if openThread?.id == thread.id { openThread = thread }
    }

    /// Quick Look for an attachment of a message: fetched first when still at the provider.
    func previewFile(for attachment: AttachmentReference, of message: MailMessageID) async throws -> URL {
        try await previewFile(for: downloaded(attachment, of: message))
    }

    /// An attachment's or inline part's bytes, hash-checked by the store.
    func attachmentData(_ attachment: AttachmentReference) async throws -> Data {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        return try await store.attachmentData(attachment)
    }

    /// Writes an attachment to a private cache file named for display, marked as downloaded
    /// (quarantine, on the Mac; iOS has no quarantine), for Quick Look. Only ever called when the user asks to see it.
    func previewFile(for attachment: AttachmentReference) async throws -> URL {
        guard let store, let quickLookFolder else { throw CocoaError(.fileNoSuchFile) }
        let data = try await store.attachmentData(attachment)
        let folder = quickLookFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(Self.previewName(attachment))
        // Complete protection is an iOS data-protection class. On the Mac, writing with it fails
        // with "permission denied" (513) on volumes without per-file data protection, which broke
        // Quick Look and Save in the attachment library; the cache folder is already private.
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        #if os(macOS)
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                                       kLSQuarantineAgentNameKey as String: "GitKittie Mail"]
        try? url.setResourceValues(values)
        #endif
        return url
    }

    /// The display name, made safe once more for a file name, with an extension that matches
    /// the declared type when the name has none (Quick Look picks its viewer by it).
    static func previewName(_ attachment: AttachmentReference) -> String {
        var name = attachment.fileName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "attachment" }
        if (name as NSString).pathExtension.isEmpty, let ext = Self.extensions[attachment.mediaType.lowercased()] { name += "." + ext }
        return String(name.prefix(120))
    }

    private static let extensions = [
        "application/pdf": "pdf", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "text/plain": "txt",
        "text/calendar": "ics", "text/csv": "csv",
    ]
}
