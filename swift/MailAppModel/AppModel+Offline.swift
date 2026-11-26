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
    /// it can fetch again: the iPhone's storage budget (MAIL-079), else 2 GB on the Mac
    /// (`defaults write app.hakobs.gitmail offlineCacheBudgetBytes <bytes>`).
    var offlineCacheBudget: Int64 {
        sync.services.offlineCacheBytes
            ?? (sync.services.defaults.object(forKey: Self.offlineCacheBudgetKey) as? Int).map(Int64.init) ?? 2 * 1024 * 1024 * 1024
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
            let result = try await mailStore?.evictCache(toFit: budget)
            // Space given back may be what a paused download waits for (MAIL-106).
            await sync.reviewFreeSpace()
            return result
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


// MARK: Storage settings (GKM-066)

extension AppModel {
    nonisolated static let onDemandThresholdKey = "onDemandThresholdBytes"
    nonisolated static let offlineCacheBudgetKey = "offlineCacheBudgetBytes"

    /// Attachments larger than `bytes` stay at the provider until opened or pinned; nil
    /// downloads every message whole. The syncs start again with it; mail already downloaded is
    /// kept as it is.
    func setOnDemandThreshold(_ bytes: Int?) async {
        sync.services.defaults.set(bytes ?? 0, forKey: Self.onDemandThresholdKey)
        guard bytes != sync.services.syncOptions.onDemandThreshold else { return }
        sync.services.syncOptions.onDemandThreshold = bytes
        guard let store = mailStore else { return }
        await sync.stopAll()
        await sync.start(accounts, store: store)
        await registerForSending(accounts)
    }

    /// The most the offline cache keeps; what is over it is given back now.
    func setOfflineCacheBudget(_ bytes: Int64) async {
        sync.services.defaults.set(Int(bytes), forKey: Self.offlineCacheBudgetKey)
        await freeUpOfflineSpace(keeping: offlineCacheBudget)
    }

    /// How much the mail folder takes on disk, counted away from the main thread.
    func mailFolderSize() async -> Int64? {
        guard let folder = mailFolder else { return nil }
        return await Task.detached(priority: .utility) { FreeSpace.allocatedSize(of: folder) }.value
    }

    /// Free space on the disk that holds the mail folder, as the system counts it for files
    /// people keep (purgeable space included).
    var freeDiskSpace: Int64? {
        mailFolder.flatMap(FreeSpace.available(at:))
    }
}

/// Space on disk, without UI: what is free (shared with the iPhone's storage budget) and what a
/// folder takes.
enum FreeSpace {
    /// Free space on the volume, as the system reports it for things the person asked for.
    static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
