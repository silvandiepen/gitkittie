import Foundation
import MailCore
import MailReader
import MailStore
import Observation

/// Which mail the list shows, from the sidebar.
enum MailScope: Hashable {
    case allMail
    case account(MailAccountID)
    case folder(MailAccountID, String)
    /// A space's messages, across accounts (GKM-022).
    case space(MailSpaceID)

    var account: MailAccountID? {
        switch self {
        case .allMail, .space: nil
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

    var isEmpty: Bool { self == SearchFilters() }
}

/// One row of the message list: a conversation, or (while searching) a single message.
enum ListRow: Identifiable, Hashable {
    case thread(ThreadSummary)
    case message(MessageSummary)

    var id: String {
        switch self {
        case .thread(let thread): "t:" + thread.id
        case .message(let message): "m:" + message.id.rawValue
        }
    }

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
    private(set) var openThread: OpenThread?
    /// An error from the last action, shown once.
    var actionError: String?
    /// Called when a read or flag change was queued for the provider (GKM-015).
    @ObservationIgnored var onActionsQueued: (@MainActor ([MailAccountID]) async -> Void)?

    private var store: MailStore?
    private var preferences: RemoteContentPreferences?
    private var quickLookFolder: URL?
    private var generation = 0
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

    func setFilters(_ filters: SearchFilters) async {
        guard filters != self.filters else { return }
        self.filters = filters
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
        return query
    }

    /// Reloads the first page. Keeps the selection when it is still in the list.
    func reload() async {
        guard let store else { return }
        generation += 1
        let mine = generation
        do {
            let found = try await page(from: store, offset: 0)
            guard mine == generation else { return } // a newer query landed meanwhile
            rows = found
            canLoadMore = found.count == Self.pageSize
            if let selected = selectedRowID, !rows.contains(where: { $0.id == selected }) {
                selectedRowID = nil
                openThread = nil
            }
        } catch {
            actionError = String(describing: error)
        }
    }

    func loadMore() async {
        guard let store, canLoadMore else { return }
        let mine = generation
        do {
            let more = try await page(from: store, offset: rows.count)
            guard mine == generation else { return }
            rows += more
            canLoadMore = more.count == Self.pageSize
        } catch {
            actionError = String(describing: error)
        }
    }

    private func page(from store: MailStore, offset: Int) async throws -> [ListRow] {
        let query = query
        if isSearching {
            return try await store.search(query, limit: Self.pageSize, offset: offset).map(ListRow.message)
        }
        return try await store.threads(query, limit: Self.pageSize, offset: offset).map(ListRow.thread)
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

    private func open(_ row: ListRow) async {
        guard let store else { return }
        do {
            let summaries = try await store.thread(row.threadID)
            guard selectedRowID == row.id else { return }
            // Newest expanded; while searching, the hit itself.
            let focus: MailMessageID? = if case .message(let hit) = row { hit.id } else { summaries.last?.id }
            var thread = OpenThread(id: row.threadID, messages: summaries.map { ThreadMessage(summary: $0, isExpanded: $0.id == focus) })
            for index in thread.messages.indices where thread.messages[index].isExpanded {
                thread.messages[index] = await loaded(thread.messages[index], store: store)
            }
            guard selectedRowID == row.id else { return }
            openThread = thread
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
    private func refreshAfterFlagChange() async {
        guard let store else { return }
        do {
            let count = max(rows.count, Self.pageSize)
            let query = query
            let fresh: [ListRow] = isSearching
                ? try await store.search(query, limit: count).map(ListRow.message)
                : try await store.threads(query, limit: count).map(ListRow.thread)
            rows = fresh
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Attachments

    /// An attachment's or inline part's bytes, hash-checked by the store.
    func attachmentData(_ attachment: AttachmentReference) async throws -> Data {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        return try await store.attachmentData(attachment)
    }

    /// Writes an attachment to a private cache file named for display, marked as downloaded
    /// (quarantine), for Quick Look. Only ever called when the user asks to see it.
    func previewFile(for attachment: AttachmentReference) async throws -> URL {
        guard let store, let quickLookFolder else { throw CocoaError(.fileNoSuchFile) }
        let data = try await store.attachmentData(attachment)
        let folder = quickLookFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(Self.previewName(attachment))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                                       kLSQuarantineAgentNameKey as String: "GitKittie Mail"]
        try? url.setResourceValues(values)
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
