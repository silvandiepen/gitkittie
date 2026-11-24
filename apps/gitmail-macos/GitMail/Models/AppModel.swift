import Foundation
import MailCore
import MailStore
import Observation

/// What the sidebar has selected.
enum SidebarSelection: Hashable {
    case allMail
    case account(MailAccountID)
    /// One folder of an account at the provider, by the provider's name for it.
    case folder(MailAccountID, String)
}

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
    private(set) var messages: [MessageSummary] = []
    private(set) var totalCount = 0
    private(set) var openMessage: StoredMessage?
    private(set) var isRebuildingIndex = false
    /// An error from the last action, for an alert; cleared when shown.
    var actionError: String?

    private(set) var selection: SidebarSelection = .allMail
    private(set) var selectedMessageID: MailMessageID?
    private(set) var searchText = ""

    private let locations: StoreLocations?
    private var store: MailStore?
    /// Accounts' sync and setup services (GKM-010, GKM-011; AppModel+Accounts.swift).
    let sync: AccountSync

    /// `locations` nil means the mail folder the person chose, or the app's standard folders
    /// (`MailFolderLocation`).
    init(locations: StoreLocations? = nil, services: AccountServices = .live) {
        self.locations = locations
        self.sync = AccountSync(services: services)
        sync.onStoreChanged = { [weak self] in await self?.refreshAfterSync() }
    }

    /// The open store, for the account intents.
    var mailStore: MailStore? { store }

    /// Where the user's mail lives, once the store is open.
    var mailFolder: URL? { store?.locations.mailFolder }

    /// True when there is nothing at all yet: no account and no message.
    var isEmpty: Bool { accounts.isEmpty && totalCount == 0 }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

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
            try await reload()
            phase = .ready
            await sync.start(accounts, store: opened)
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func select(_ selection: SidebarSelection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        await refreshList()
        if case .folder(let account, let name) = selection { await sync.setActiveFolder(name, account: account) }
    }

    func search(_ text: String) async {
        guard text != searchText else { return }
        searchText = text
        await refreshList()
    }

    func selectMessage(_ id: MailMessageID?) async {
        selectedMessageID = id
        guard let id, let store else { openMessage = nil; return }
        do {
            let message = try await store.message(id)
            // A later selection may have landed while this one was reading.
            if selectedMessageID == id { openMessage = message }
        } catch {
            openMessage = nil
            actionError = String(describing: error)
        }
    }

    /// Makes the search index again from the mail folder.
    func rebuildIndex() async {
        guard let store, !isRebuildingIndex else { return }
        isRebuildingIndex = true
        defer { isRebuildingIndex = false }
        do {
            try await store.rebuildIndex()
            try await reload()
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Loading

    /// After an account was added or removed.
    func reloadAfterAccountChange() async throws { try await reload() }

    /// After the sync stored mail or saw new folders: counts and the list, keeping the selection.
    func refreshAfterSync() async {
        guard let store else { return }
        do {
            totalCount = try await store.messageCount()
            try await loadList(from: store)
        } catch {
            actionError = String(describing: error)
        }
    }

    private func reload() async throws {
        guard let store else { return }
        accounts = try await store.accounts()
        totalCount = try await store.messageCount()
        if let id = selection.account, !accounts.contains(where: { $0.id == id }) { selection = .allMail }
        try await loadList(from: store)
    }

    private func refreshList() async {
        guard let store else { return }
        do {
            try await loadList(from: store)
        } catch {
            actionError = String(describing: error)
        }
    }

    private func loadList(from store: MailStore) async throws {
        let account = selection.account
        let query = searchText
        let found: [MessageSummary]
        if isSearching {
            found = try await store.search(query, account: account)
        } else if case .folder(let id, let mailbox) = selection {
            found = try await store.summaries(account: id, mailbox: mailbox)
        } else {
            found = try await store.summaries(account: account)
        }
        // Typing fast: only the newest query's results are shown.
        guard query == searchText else { return }
        messages = found
        if let selected = selectedMessageID, !found.contains(where: { $0.id == selected }) {
            selectedMessageID = nil
            openMessage = nil
        }
    }
}
