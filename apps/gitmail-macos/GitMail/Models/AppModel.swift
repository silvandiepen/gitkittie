import Foundation
import MailCore
import MailStore
import Observation

/// What the sidebar has selected.
enum SidebarSelection: Hashable {
    case allMail
    case account(MailAccountID)
    /// Messages being written (GKM-013).
    case drafts
    /// Messages waiting to be sent, or needing a decision (GKM-014).
    case outbox
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

    /// Drafts and the outbox; nil until the store is open.
    private(set) var sending: MailSending?

    private let locations: StoreLocations?
    private var store: MailStore?

    /// `locations` nil means the app's standard folders (`StoreLocations.standard()`).
    init(locations: StoreLocations? = nil) {
        self.locations = locations
    }

    /// Where the user's mail lives, once the store is open.
    var mailFolder: URL? { store?.locations.mailFolder }

    /// True when there is nothing at all yet: no account and no message.
    var isEmpty: Bool { accounts.isEmpty && totalCount == 0 }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedAccount: MailAccount? {
        guard case .account(let id) = selection else { return nil }
        return accounts.first { $0.id == id }
    }

    // MARK: Intents

    func open() async {
        phase = .opening
        do {
            let opened = try await MailStore.open(locations ?? StoreLocations.standard())
            store = opened
            if sending == nil {
                let sending = try MailSending(locations: opened.locations, credentials: KeychainCredentials())
                sending.start()
                await sending.refreshDrafts()
                self.sending = sending
            }
            try await reload()
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func select(_ selection: SidebarSelection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        await refreshList()
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
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Loading

    private func reload() async throws {
        guard let store else { return }
        accounts = try await store.accounts()
        totalCount = try await store.messageCount()
        if case .account(let id) = selection, !accounts.contains(where: { $0.id == id }) { selection = .allMail }
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
        let account: MailAccountID? = if case .account(let id) = selection { id } else { nil }
        let query = searchText
        let found = isSearching ? try await store.search(query, account: account) : try await store.summaries(account: account)
        // Typing fast: only the newest query's results are shown.
        guard query == searchText else { return }
        messages = found
        if let selected = selectedMessageID, !found.contains(where: { $0.id == selected }) {
            selectedMessageID = nil
            openMessage = nil
        }
    }
}
