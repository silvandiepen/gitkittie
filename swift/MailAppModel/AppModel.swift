import Foundation
import MailClassifier
import MailCore
import MailExtraction
import MailStore
import Observation

/// What the sidebar has selected.
enum SidebarSelection: Hashable {
    case allMail
    /// Focused and the category views (GKM-018).
    case category(MailCategory)
    case account(MailAccountID)
    /// A provider folder of an account, as this device's sync state knows it (GKM-012).
    case folder(MailAccountID, String)
    /// Messages being written (GKM-013).
    case drafts
    /// Messages waiting to be sent, or needing a decision (GKM-014).
    case outbox
    /// A space's messages and attachments, across accounts (GKM-022).
    case space(MailSpaceID)
    /// Every attachment across accounts (GKM-023).
    case attachments
    /// Senders and lists, their rules and unsubscribe (GKM-019, GKM-020).
    case senders
    /// The cleanup dashboard (GKM-021).
    case cleanup

    /// The mail the list shows for it (drafts and the outbox have their own views).
    var scope: MailScope {
        switch self {
        case .allMail, .drafts, .outbox, .attachments, .senders, .cleanup: .allMail
        case .category(let category): .category(category)
        case .space(let id): .space(id)
        case .account(let id): .account(id)
        case .folder(let id, let name): .folder(id, name)
        }
    }
}

/// Turns attachment bytes into text for search. On the Mac it is the isolated XPC service
/// (`IsolatedTextExtractor`), so nothing in the app process parses a PDF; iOS has no XPC
/// services for apps and parses in process within strict limits (MAIL-052).
protocol AttachmentTextExtracting: Sendable {
    func extract(_ data: Data, mediaType: String) async -> String?
}

#if os(macOS)
extension IsolatedTextExtractor: AttachmentTextExtracting {}
#else
extension InProcessTextExtractor: AttachmentTextExtracting {}
#endif

/// The single UI-facing state object. It owns the store and turns what the store holds into
/// what the window shows; views render it and send intents back, nothing more.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case opening
        case ready
        /// The store could not be opened; the message says why, in words.
        case failed(String)
    }

    private(set) var phase: Phase = .opening
    private(set) var accounts: [MailAccount] = []
    /// Each account's folders that hold stored mail.
    private(set) var folders: [MailAccountID: [String]] = [:]
    private(set) var totalCount = 0
    private(set) var isRebuildingIndex = false
    private(set) var isImporting = false
    /// What the last import did, for a notice; cleared when shown.
    var importReport: ImportReport?
    /// The message list, the open thread and search (GKM-012, GKM-016).
    let browser: MailBrowser
    /// Spaces (GKM-022) and the attachment library (GKM-023).
    let spaces = SpacesModel()
    let library = AttachmentLibraryModel()
    /// What the last export did, for a notice; cleared when shown (GKM-023).
    var exportReport: ExportReport?
    /// Everyday actions with Undo, sent through each account's action journal (GKM-015).
    let actions: MailActions
    /// Senders and lists, their rules, and unsubscribe (GKM-019, GKM-020; Models/Senders).
    let senders: SendersModel
    /// The cleanup dashboard: analysis and batch previews (GKM-021).
    let cleanup: CleanupModel

    /// The message the reader is focused on (the newest expanded one in the open thread):
    /// what Reply, Reply All and Forward answer.
    var openMessage: StoredMessage? {
        guard let thread = browser.openThread else { return nil }
        return thread.messages.last(where: { $0.isExpanded && $0.stored != nil })?.stored
    }
    /// An error from the last action, for an alert; cleared when shown.
    var actionError: String?

    /// Focused is where the window opens (GKM-018).
    private(set) var selection: SidebarSelection = .category(.focused)
    /// Where "See All Mail from…" was opened from, to go back to.
    private(set) var senderReturn: SidebarSelection?

    /// A notification that was opened before the store was (GKM-037): shown once it is.
    @ObservationIgnored private var pendingNotification: MailMessageID?
    /// Counts the conversations opened from a notification, so the iPhone can show the reader.
    private(set) var notificationOpens = 0
    /// Holds the notification centre's delegate, which it keeps only weakly.
    @ObservationIgnored var notificationResponder: AnyObject?

    /// Drafts and the outbox; nil until the store is open.
    private(set) var sending: MailSending?
    /// The mail folder `sending` belongs to.
    @ObservationIgnored private var sendingFolder: URL?

    private let locations: StoreLocations?
    private var store: MailStore?
    private let extractor: (any AttachmentTextExtracting)?
    private var extraction: Task<Void, Never>?
    /// False while attachment text must not be extracted: iOS extracts only while the app is
    /// active or in a processing task (MAIL-052). Always true on the Mac.
    @ObservationIgnored var extractsAttachmentText = true
    /// Accounts' sync and setup services (GKM-010, GKM-011; AppModel+Accounts.swift).
    let sync: AccountSync
    /// Category counts, the badge, background classification and notifications (GKM-017,
    /// GKM-018; AppModel+Classification.swift).
    let attention: MailAttention

    /// `locations` nil means the mail folder the person chose, or the app's standard folders
    /// (`MailFolderLocation`).
    init(locations: StoreLocations? = nil, extractor: (any AttachmentTextExtracting)? = nil,
         services: AccountServices = .live, notifications: (any MailNotificationPosting)? = nil) {
        self.locations = locations
        self.extractor = extractor
        let sync = AccountSync(services: services)
        let browser = MailBrowser()
        self.sync = sync
        self.browser = browser
        let actions = MailActions(sync: sync, browser: browser)
        self.actions = actions
        self.cleanup = CleanupModel(actions: actions, browser: browser)
        self.attention = MailAttention(poster: notifications)
        self.senders = SendersModel(actions: actions, browser: browser, unsubscribe: UnsubscribeModel())
        sync.onStoreChanged = { [weak self] in await self?.refreshAfterSync() }
        browser.onActionsQueued = { [weak self] accounts in await self?.sync.actionsQueued(for: accounts) }
        browser.onMessagesOpened = { [weak self] ids in await self?.senders.recordOpen(ids) }
        browser.sync = sync
        browser.onFetchAttachment = { [weak self] attachment, id in
            guard let self else { throw CancellationError() }
            return try await self.fetchAttachment(attachment, of: id)
        }
        actions.onMailChanged = { [weak self] in await self?.refreshAfterMailChange() }
        senders.onPlacementsChanged = { [weak self] in
            guard let self else { return }
            await self.attention.refresh(accounts: self.accounts, arrivals: .leave)
        }
        senders.unsubscribe.accountAddresses = { [weak self] account in
            guard let found = self?.accounts.first(where: { $0.id == account }), !found.address.isEmpty else { return [] }
            return [found.sendingAddress]
        }
    }

    /// The open store, for the account intents.
    var mailStore: MailStore? { store }

    /// Where the user's mail lives, once the store is open.
    var mailFolder: URL? { store?.locations.mailFolder }

    /// True when there is nothing at all yet: no account and no message.
    var isEmpty: Bool { accounts.isEmpty && totalCount == 0 }

    /// The account of the selection: the account itself or one of its folders.
    var selectedAccount: MailAccount? {
        guard let id = selection.account else { return nil }
        return accounts.first { $0.id == id }
    }

    // MARK: Intents

    func open() async {
        phase = .opening
        await sync.stopAll()
        do {
            let folder = MailFolderLocation(defaults: sync.services.defaults)
            let opened = try await MailStore.open(locations ?? folder.locations())
            store = opened
            browser.attach(opened)
            actions.attach(opened)
            cleanup.attach(opened)
            spaces.attach(opened)
            library.attach(opened, browser: browser)
            await senders.attach(opened)
            await browser.setScope(selection.scope)
            try await attention.attach(opened)
            if let current = sending, sendingFolder != opened.locations.mailFolder {
                // Another mail folder was chosen: its drafts and outbox are its own.
                await current.stop()
                sending = nil
            }
            if sending == nil {
                let sending = try MailSending(locations: opened.locations, credentials: KeychainCredentials())
                sending.start()
                await sending.refreshDrafts()
                self.sending = sending
                sendingFolder = opened.locations.mailFolder
            }
            senders.unsubscribe.sending = sending
            try await reload()
            phase = .ready
            if let pending = pendingNotification {
                pendingNotification = nil
                await openFromNotification(pending)
            }
            await sync.start(accounts, store: opened)
            await registerForSending(accounts)
            indexAttachmentTextInBackground()
            attention.classifyInBackground { [weak self] in await self?.browser.reload() }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func select(_ selection: SidebarSelection) async {
        senderReturn = nil
        guard selection != self.selection else { return }
        self.selection = selection
        await browser.setScope(selection.scope)
        if case .folder(let account, let name) = selection { await sync.setActiveFolder(name, account: account) }
    }

    /// "See All Mail from…" (GKM-071, MAIL-098): All Mail, every account and folder, narrowed to
    /// exactly this sender's address by the From chip. Escape or the chip's close goes back.
    func showAllMail(from sender: MailAddress) async {
        let back = senderReturn ?? selection
        await select(.allMail)
        await browser.showSender(sender)
        senderReturn = back
    }

    /// Ends "See All Mail from…": the From chip off, back to the view it started from.
    func leaveSenderView() async {
        guard browser.filters.sender != nil else { return }
        let back = senderReturn
        var filters = browser.filters
        filters.sender = nil
        await browser.setFilters(filters)
        if let back { await select(back) }
    }

    /// A notification was clicked (GKM-037, MAIL-086): show its conversation. The list stays
    /// where it is when it already shows the conversation; otherwise it goes to the view the
    /// message lives in (Focused, or the category an Always list or space notified from), with
    /// the search cleared. Before the store is open, it waits for it.
    func openFromNotification(_ id: MailMessageID) async {
        guard phase == .ready, let store else {
            pendingNotification = id
            return
        }
        do {
            guard let summary = try await store.summary(of: id) else {
                actionError = "That message is no longer on \(DeviceWords.this)."
                return
            }
            let showsMail: Bool = switch selection {
            case .allMail, .category, .account, .folder, .space: true
            case .drafts, .outbox, .attachments, .senders, .cleanup: false
            }
            if !showsMail || browser.isSearching || !browser.rows.contains(where: { $0.threadID == summary.threadID }) {
                let home = try await store.verdict(of: id)?.home ?? .focused
                await browser.clearSearch()
                await select(.category(home))
            }
            await browser.reveal(id, threadID: summary.threadID)
            notificationOpens += 1
        } catch {
            actionError = String(describing: error)
        }
    }

    /// File ▸ Import Messages…: `.eml` files and folders of them, into "On My Mac".
    func importMessages(from urls: [URL]) async {
        guard let store, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let report = await MailImporter.importMessages(from: urls, into: store)
        importReport = report
        do { try await reload() } catch { actionError = String(describing: error) }
        // New mail may match a space's rules.
        if await spaces.refresh(applyRules: true) > 0 { await browser.reload() }
        await attention.refresh(accounts: accounts, arrivals: .skip)
        indexAttachmentTextInBackground()
    }

    /// Extracts text from PDF and plain-text attachments that have none yet, one at a time,
    /// through the isolated extractor (GKM-016). Runs after opening and after an import.
    func indexAttachmentTextInBackground() {
        guard extractsAttachmentText, extraction == nil, let store, let extractor else { return }
        extraction = Task { [weak self] in
            await Self.indexAttachmentText(store: store, extractor: extractor)
            self?.extraction = nil
        }
    }

    /// Stops extracting attachment text, for now (MAIL-052); what was extracted is kept, and
    /// `indexAttachmentTextInBackground()` carries on later.
    func pauseAttachmentText() {
        extractsAttachmentText = false
        extraction?.cancel()
        extraction = nil
    }

    /// Waits for the background extraction, for tests.
    func waitForAttachmentText() async { await extraction?.value }

    nonisolated static func indexAttachmentText(store: MailStore, extractor: any AttachmentTextExtracting) async {
        var failures = 0
        while !Task.isCancelled {
            guard let pending = try? await store.attachmentsNeedingText(mediaTypes: AttachmentTextExtractor.supportedMediaTypes, limit: 20),
                  !pending.isEmpty else { return }
            for item in pending {
                guard let data = try? await store.blobData(item.blob) else { failures += 1; continue }
                let text = await extractor.extract(data, mediaType: item.mediaType)
                // No text (unsupported, too big, crashed or timed out) is recorded too, so a
                // hostile attachment is tried once, not on every launch.
                if (try? await store.recordAttachmentText(text, forBlob: item.blob)) == nil { failures += 1 }
            }
            if failures > 50 { return }
        }
    }

    /// The original bytes of a stored message, for Reply and Forward.
    func originalData(of id: MailMessageID) async throws -> Data {
        guard let store else { throw MailStoreError.messageNotFound(id.rawValue) }
        return try await store.originalData(of: id)
    }

    /// Makes the search index again from the mail folder.
    func rebuildIndex() async {
        guard let store, !isRebuildingIndex else { return }
        isRebuildingIndex = true
        defer { isRebuildingIndex = false }
        do {
            try await store.rebuildIndex()
            try await reload()
            indexAttachmentTextInBackground()
            attention.classifyInBackground { [weak self] in await self?.browser.reload() }
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Loading

    /// After an account was added or removed.
    func reloadAfterAccountChange() async throws { try await reload() }

    /// After the sync stored mail or saw new folders: counts, folders and the list, keeping the
    /// selection and the open thread.
    func refreshAfterSync() async {
        guard let store else { return }
        do {
            totalCount = try await store.messageCount()
            var found: [MailAccountID: [String]] = [:]
            for account in accounts { found[account.id] = try await store.folders(account: account.id) }
            folders = found
        } catch {
            actionError = String(describing: error)
        }
        // Synced mail may match a space's rules (GKM-022).
        await spaces.refresh(applyRules: true)
        await browser.reload()
        await attention.refresh(accounts: accounts, arrivals: .notify)
        await senders.afterSync()
    }

    /// After an action, its Undo or Redo: the category counts, the badge and the spaces' counts
    /// are re-read at once, as the list is (mail moved to Trash or Junk leaves them; GKM-075).
    func refreshAfterMailChange() async {
        await spaces.refresh()
        await attention.refresh(accounts: accounts, arrivals: .leave)
        // The Senders view's numbers, once it has been opened.
        if !senders.senders.isEmpty { await senders.refresh() }
    }

    private func reload() async throws {
        guard let store else { return }
        accounts = AccountOrder.load(deviceFolder: store.locations.deviceFolder).sorted(try await store.accounts())
        totalCount = try await store.messageCount()
        var found: [MailAccountID: [String]] = [:]
        for account in accounts { found[account.id] = try await store.folders(account: account.id) }
        folders = found
        await spaces.refresh(applyRules: true)
        let stillThere: Bool = switch selection {
        case .allMail, .category, .drafts, .outbox, .attachments, .senders, .cleanup: true
        case .space(let id): spaces.space(id) != nil
        case .account(let id): accounts.contains { $0.id == id }
        case .folder(let id, let name):
            // A folder with stored mail, or one the sync knows at the provider (may be empty).
            found[id]?.contains(name) == true || sync.folders[id]?.contains { $0.name == name } == true
        }
        if !stillThere {
            selection = .category(.focused)
            await browser.setScope(selection.scope)
        }
        await browser.reload()
        await attention.refresh(accounts: accounts, arrivals: .leave)
    }
}
