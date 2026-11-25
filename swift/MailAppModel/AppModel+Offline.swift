import Foundation
import MailCore
import MailStore
import MailSync

/// Attachments on demand and pin for offline (GKM-036; MAIL-062, MAIL-063): the account's
/// on-demand fetcher behind the reader, the attachment library, export and Forward; pins on a
/// message, a conversation or a space; and the offline cache for Settings.
extension AppModel {
    enum OfflineError: Error, CustomStringConvertible {
        case notSyncing

        var description: String {
            switch self {
            case .notSyncing: "This account doesn’t sync on this Mac, so its attachments can’t be downloaded here."
            }
        }
    }

    /// Attachments larger than this stay at the provider until opened or pinned.
    var onDemandThreshold: Int { sync.services.syncOptions.onDemandThreshold ?? 0 }

    /// The most the offline cache keeps before it gives back the least recently opened parts
    /// it can fetch again (`defaults write app.hakobs.gitmail offlineCacheBudgetBytes <bytes>`).
    var offlineCacheBudget: Int64 {
        (sync.services.defaults.object(forKey: "offlineCacheBudgetBytes") as? Int).map(Int64.init) ?? 2 * 1024 * 1024 * 1024
    }

    /// Fetches an attachment a partial message left at the provider, once; then keeps the
    /// cache within its budget.
    func fetchAttachment(_ attachment: AttachmentReference, of id: MailMessageID) async throws -> AttachmentReference {
        guard let store = mailStore else { throw MailStoreError.messageNotFound(id.rawValue) }
        guard let account = try await store.summaries(ids: [id]).first?.account else { throw MailStoreError.messageNotFound(id.rawValue) }
        guard let fetcher = sync.fetcher(for: account) else { throw OfflineError.notSyncing }
        let fetched = try await fetcher.fetchAttachment(attachment, of: id)
        if let storage = try? await store.offlineStorage(), storage.cacheBytes > offlineCacheBudget {
            // Never the part just opened: it is the most recently used.
            _ = try? await store.evictCache(toFit: offlineCacheBudget)
        }
        return fetched
    }

    /// The bytes Reply quotes from: the original, or a partial message's header and text.
    func replySource(of id: MailMessageID) async throws -> Data {
        guard let store = mailStore else { throw MailStoreError.messageNotFound(id.rawValue) }
        return try await store.replySource(of: id)
    }

    /// Downloads the whole originals of partial messages where their account syncs here.
    /// Offline or not syncing, they stay partial: callers check what is still partial.
    func completePartialMessages(_ items: [(id: MailMessageID, account: MailAccountID)]) async {
        let byAccount = Dictionary(grouping: items, by: \.account)
        for (account, entries) in byAccount {
            guard let fetcher = sync.fetcher(for: account) else { continue }
            do {
                try await fetcher.complete(entries.map(\.id))
            } catch {
                actionError = String(describing: error)
            }
        }
    }

    // MARK: Pins

    func isPinned(_ target: PinTarget) async -> Bool {
        (try? await mailStore?.isPinned(target)) ?? false
    }

    /// Keeps a message, conversation or space offline: what it covers is downloaded whole now
    /// when online, else by the sync's next pass.
    func pin(_ target: PinTarget) async {
        guard let store = mailStore else { return }
        do {
            let waiting = try await store.pin(target)
            guard !waiting.isEmpty else { return }
            var items: [(id: MailMessageID, account: MailAccountID)] = []
            for summary in try await store.summaries(ids: waiting) { items.append((summary.id, summary.account)) }
            Task { [weak self] in await self?.completePartialMessages(items) }
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Stops keeping it offline. What is downloaded stays; only parts fetched for partial
    /// messages may later be given back by the cache.
    func unpin(_ target: PinTarget) async {
        do { try await mailStore?.unpin(target) } catch { actionError = String(describing: error) }
    }

    // MARK: Storage

    func offlineStorage() async -> OfflineStorage? {
        try? await mailStore?.offlineStorage()
    }

    /// Gives back cached attachments of partial messages, keeping at most `budget` bytes.
    @discardableResult
    func freeUpOfflineSpace(keeping budget: Int64) async -> EvictionResult? {
        do {
            return try await mailStore?.evictCache(toFit: budget)
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }
}

// MARK: History window (GKM-060, MAIL-072)

extension AppModel {
    /// How far back each folder's history is downloaded, in days; nil downloads all of it.
    var historyDays: Int? { sync.services.syncOptions.historyDays }

    /// Messages at the providers older than the window and not downloaded, over every account.
    var olderNotDownloaded: Int { sync.progress.values.reduce(0) { $0 + $1.olderNotDownloaded } }

    /// Saves a new window and restarts the syncs with it: a running sync keeps the options it
    /// started with. Widening it (or nil) downloads the older mail newest first, without
    /// duplicates; narrowing it never deletes mail already downloaded.
    func setHistoryDays(_ days: Int?) async {
        sync.services.defaults.set(days ?? 0, forKey: AccountServices.historyDaysKey)
        guard days != historyDays else { return }
        sync.services.syncOptions.historyDays = days
        guard let store = mailStore else { return }
        await sync.stopAll()
        await sync.start(accounts, store: store)
        await registerForSending(accounts)
    }
}

