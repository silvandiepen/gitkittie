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

    /// The mail the list shows for it.
    var scope: MailScope {
        switch self {
        case .allMail: .allMail
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
    let browser = MailBrowser()
    /// An error from the last action, for an alert; cleared when shown.
    var actionError: String?

    private(set) var selection: SidebarSelection = .allMail

    private let locations: StoreLocations?
    private var store: MailStore?
    private let extractor: (any AttachmentTextExtracting)?
    private var extraction: Task<Void, Never>?

    /// `locations` nil means the app's standard folders (`StoreLocations.standard()`).
    init(locations: StoreLocations? = nil, extractor: (any AttachmentTextExtracting)? = nil) {
        self.locations = locations
        self.extractor = extractor
    }

    /// Where the user's mail lives, once the store is open.
    var mailFolder: URL? { store?.locations.mailFolder }

    /// True when there is nothing at all yet: no account and no message.
    var isEmpty: Bool { accounts.isEmpty && totalCount == 0 }

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
            browser.attach(opened)
            try await reload()
            phase = .ready
            indexAttachmentTextInBackground()
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func select(_ selection: SidebarSelection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        await browser.setScope(selection.scope)
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

    private func reload() async throws {
        guard let store else { return }
        accounts = try await store.accounts()
        totalCount = try await store.messageCount()
        var found: [MailAccountID: [String]] = [:]
        for account in accounts { found[account.id] = try await store.folders(account: account.id) }
        folders = found
        let stillThere: Bool = switch selection {
        case .allMail: true
        case .account(let id): accounts.contains { $0.id == id }
        case .folder(let id, let name): found[id]?.contains(name) == true
        }
        if !stillThere {
            selection = .allMail
            await browser.setScope(.allMail)
        }
        await browser.reload()
    }
}
