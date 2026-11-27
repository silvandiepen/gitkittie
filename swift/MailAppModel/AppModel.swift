import Foundation
import MailClassifier
import MailCore
import MailExtraction
import MailStore
import Observation

/// What the sidebar has selected. Codable: the window opens where it was left (MAIL-107).
enum SidebarSelection: Hashable, Codable {
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

    /// True when the window shows the message list and the reader for it.
    var showsMail: Bool {
        switch self {
        case .allMail, .category, .account, .folder, .space: true
        case .drafts, .outbox, .attachments, .senders, .cleanup: false
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
    /// The encrypted archive being written or restored, and its recovery key while it is shown (GKM-032).
    let encryptedArchive = EncryptedArchiveModel()
    /// Everyday actions with Undo, sent through each account's action journal (GKM-015).
    let actions: MailActions
    /// Senders and lists, their rules, and unsubscribe (GKM-019, GKM-020; Models/Senders).
    let senders: SendersModel
    /// The cleanup dashboard: analysis and batch previews (GKM-021).
    let cleanup: CleanupModel
    /// Active organisation and retention: active mode per account, policies, the history (GKM-031).
    let organisation: OrganisationModel

    /// The message the reader is focused on (the newest expanded one in the open thread):
    /// what Reply, Reply All and Forward answer.
    var openMessage: StoredMessage? {
        guard let thread = browser.openThread else { return nil }
        return thread.messages.last(where: { $0.isExpanded && $0.stored != nil })?.stored
    }
    /// An error from the last action, for an alert; cleared when shown.
    var actionError: String?

    /// The window opens where it was left (MAIL-107), else in Focused (GKM-018).
    private(set) var selection: SidebarSelection = .category(.focused)
    /// True while `open()` puts the window back where it was: what changes meanwhile is not a
    /// new place to remember.
    @ObservationIgnored private var restoringPlace = false
    /// Where "See All Mail from…" was opened from, to go back to.
    private(set) var senderReturn: SidebarSelection?

    /// A notification or a message link opened before the store was (GKM-037, GKM-033): shown
    /// once it is. The last one wins.
    @ObservationIgnored var pendingOpen: PendingOpen?
    /// Counts the conversations opened from a notification or a message link, so the iPhone
    /// can show the reader.
    private(set) var externalOpens = 0
    /// Holds the notification centre's delegate, which it keeps only weakly.
    @ObservationIgnored var notificationResponder: AnyObject?

    /// Drafts and the outbox; nil until the store is open.
    private(set) var sending: MailSending?
    /// The mail folder `sending` belongs to.
    @ObservationIgnored private var sendingFolder: URL?

    private let locations: StoreLocations?
    /// The folders a mail folder's device state is placed beside (`MailFolderLocation`): the ones
    /// this model was made with, else the app's standard ones.
    func standardLocations() throws -> StoreLocations { try locations ?? StoreLocations.standard() }
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
        self.organisation = OrganisationModel(actions: actions, sync: sync)
        senders.organisation = organisation
        sync.onStoreChanged = { [weak self] in await self?.refreshAfterSync() }
        browser.onActionsQueued = { [weak self] accounts in await self?.sync.actionsQueued(for: accounts) }
        browser.onMessagesOpened = { [weak self] ids in await self?.senders.recordOpen(ids) }
        browser.sync = sync
        browser.onOpenThreadChanged = { [weak self] in self?.rememberPlace() }
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
            await organisation.attach(opened)
            // Back where the window was left (MAIL-107); `reload` falls back to Focused when
            // that view is gone, and the conversation opens again only if the view still has it.
            restoringPlace = true
            defer { restoringPlace = false }
            let place = LastPlace.load(deviceFolder: opened.locations.deviceFolder)
            selection = place?.selection ?? .category(.focused)
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
            if let place, let thread = place.threadID, place.selection == selection, selection.showsMail {
                await browser.reopen(thread)
            }
            restoringPlace = false
            rememberPlace()
            phase = .ready
            if let pending = pendingOpen {
                pendingOpen = nil
                switch pending {
                case .message(let id): await openFromNotification(id)
                case .link(let link): await open(link)
                }
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
        rememberPlace()
    }

    /// Saves where the window is (MAIL-107): the sidebar's selection and the open conversation.
    /// A failed write loses only the place: the window then opens in Focused.
    func rememberPlace() {
        guard !restoringPlace, let store else { return }
        let thread = selection.showsMail ? browser.openThread?.id : nil
        try? LastPlace(selection: selection, threadID: thread).save(deviceFolder: store.locations.deviceFolder)
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
            pendingOpen = .message(id)
            return
        }
        do {
            guard let summary = try await store.summary(of: id) else {
                actionError = "That message is no longer on \(DeviceWords.this)."
                return
            }
            if !selection.showsMail || browser.isSearching || !browser.rows.contains(where: { $0.threadID == summary.threadID }) {
                let home = try await store.verdict(of: id)?.home ?? .focused
                await browser.clearSearch()
                await select(.category(home))
            }
            await browser.reveal(id, threadID: summary.threadID)
            externalOpens += 1
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
        await organisation.afterSync()
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
        var stillThere: Bool
        switch selection {
        case .allMail, .category, .drafts, .outbox, .attachments, .senders, .cleanup: stillThere = true
        case .space(let id): stillThere = spaces.space(id) != nil
        case .account(let id): stillThere = accounts.contains { $0.id == id }
        case .folder(let id, let name):
            // A folder with stored mail, or one the sync knows at the provider (may be empty;
            // before the sync starts, as the sync state last recorded it).
            stillThere = found[id]?.contains(name) == true || sync.folders[id]?.contains { $0.name == name } == true
            if !stillThere { stillThere = (try? await store.syncedFolders(account: id))?.contains { $0.name == name } == true }
        }
        if !stillThere {
            selection = .category(.focused)
            await browser.setScope(selection.scope)
            rememberPlace()
        }
        await browser.reload()
        await attention.refresh(accounts: accounts, arrivals: .leave)
    }
}
