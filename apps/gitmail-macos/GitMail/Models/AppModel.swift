import Foundation
import MailCore
import MailExtraction
import MailStore
import Observation

/// What the sidebar has selected.
enum SidebarSelection: Hashable {
    case allMail
    case account(MailAccountID)
    /// A provider folder of an account, as this device's sync state knows it (GKM-012).
    case folder(MailAccountID, String)
    /// Messages being written (GKM-013).
    case drafts
    /// Messages waiting to be sent, or needing a decision (GKM-014).
    case outbox

    /// The mail the list shows for it (drafts and the outbox have their own views).
    var scope: MailScope {
        switch self {
        case .allMail, .drafts, .outbox: .allMail
        case .account(let id): .account(id)
        case .folder(let id, let name): .folder(id, name)
        }
    }
}

/// Turns attachment bytes into text for search. The app's is the isolated XPC service
/// (`IsolatedTextExtractor`); nothing in the app process parses a PDF.
protocol AttachmentTextExtracting: Sendable {
    func extract(_ data: Data, mediaType: String) async -> String?
}

extension IsolatedTextExtractor: AttachmentTextExtracting {}

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
    /// Everyday actions with Undo, sent through each account's action journal (GKM-015).
    let actions: MailActions

    /// The message the reader is focused on (the newest expanded one in the open thread):
    /// what Reply, Reply All and Forward answer.
    var openMessage: StoredMessage? {
        guard let thread = browser.openThread else { return nil }
        return thread.messages.last(where: { $0.isExpanded && $0.stored != nil })?.stored
    }
    /// An error from the last action, for an alert; cleared when shown.
    var actionError: String?

    private(set) var selection: SidebarSelection = .allMail

    /// Drafts and the outbox; nil until the store is open.
    private(set) var sending: MailSending?
    /// The mail folder `sending` belongs to.
    @ObservationIgnored private var sendingFolder: URL?

    private let locations: StoreLocations?
    private var store: MailStore?
    private let extractor: (any AttachmentTextExtracting)?
    private var extraction: Task<Void, Never>?
    /// Accounts' sync and setup services (GKM-010, GKM-011; AppModel+Accounts.swift).
    let sync: AccountSync

    /// `locations` nil means the mail folder the person chose, or the app's standard folders
    /// (`MailFolderLocation`).
    init(locations: StoreLocations? = nil, extractor: (any AttachmentTextExtracting)? = nil,
         services: AccountServices = .live) {
        self.locations = locations
        self.extractor = extractor
        let sync = AccountSync(services: services)
        let browser = MailBrowser()
        self.sync = sync
        self.browser = browser
        self.actions = MailActions(sync: sync, browser: browser)
        sync.onStoreChanged = { [weak self] in await self?.refreshAfterSync() }
        browser.onActionsQueued = { [weak self] accounts in await self?.sync.actionsQueued(for: accounts) }
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
            try await reload()
            phase = .ready
            await sync.start(accounts, store: opened)
            await registerForSending(accounts)
            indexAttachmentTextInBackground()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func select(_ selection: SidebarSelection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        await browser.setScope(selection.scope)
        if case .folder(let account, let name) = selection { await sync.setActiveFolder(name, account: account) }
    }

    /// File ▸ Import Messages…: `.eml` files and folders of them, into "On My Mac".
    func importMessages(from urls: [URL]) async {
        guard let store, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let report = await MailImporter.importMessages(from: urls, into: store)
        importReport = report
        do { try await reload() } catch { actionError = String(describing: error) }
        indexAttachmentTextInBackground()
    }

    /// Extracts text from PDF and plain-text attachments that have none yet, one at a time,
    /// through the isolated extractor (GKM-016). Runs after opening and after an import.
    func indexAttachmentTextInBackground() {
        guard extraction == nil, let store, let extractor else { return }
        extraction = Task { [weak self] in
            await Self.indexAttachmentText(store: store, extractor: extractor)
            self?.extraction = nil
        }
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
        await browser.reload()
    }

    private func reload() async throws {
        guard let store else { return }
        accounts = try await store.accounts()
        totalCount = try await store.messageCount()
        var found: [MailAccountID: [String]] = [:]
        for account in accounts { found[account.id] = try await store.folders(account: account.id) }
        folders = found
        let stillThere: Bool = switch selection {
        case .allMail, .drafts, .outbox: true
        case .account(let id): accounts.contains { $0.id == id }
        case .folder(let id, let name):
            // A folder with stored mail, or one the sync knows at the provider (may be empty).
            found[id]?.contains(name) == true || sync.folders[id]?.contains { $0.name == name } == true
        }
        if !stillThere {
            selection = .allMail
            await browser.setScope(.allMail)
        }
        await browser.reload()
    }
}
