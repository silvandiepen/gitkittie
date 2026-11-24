import Foundation
import MailCore
import MailProvider
import MailStore

/// Keeps one account's mail in the store in step with the provider (GKM-011; Architecture.md,
/// Multi-device sync).
///
/// - **Progressive.** Each pass imports every folder's new mail first (on a first sync, the
///   newest ``SyncOptions/recentPerFolder`` messages), newest first, then flags and removals,
///   then a slice of history, newest first, within the storage budget. Between slices it checks
///   for new mail again, so a long history import never hides today's mail.
/// - **Never loses or duplicates.** What is stored is decided by the store's remote mapping
///   (mailbox + UIDVALIDITY + UID → local id), which `ingest` writes only after the `.eml` is
///   durable. Cursors are checkpointed after the writes they cover. A message seen again —
///   after a UIDVALIDITY reset, a move, or as a copy in a second folder — is matched to the
///   stored one when the bytes are identical, and gets a second location instead of a copy.
/// - **Keeps up.** After a pass it waits on the active folder with IDLE (or polling when the
///   server has none), syncs that folder on a change, and checks every folder when the wait
///   times out. A dropped connection reconnects with backoff; a refused password stops the
///   sync and says so.
public actor SyncCoordinator {
    public nonisolated let account: MailAccountID
    /// Every change in what the sync is doing; the newest is what the app shows.
    public nonisolated let updates: AsyncStream<SyncProgress>

    private let connector: any MailboxConnector
    private let store: MailStore
    private let options: SyncOptions
    private let log: MailLog
    private let continuation: AsyncStream<SyncProgress>.Continuation
    private var loop: Task<Void, Never>?
    private var activeFolder: String?
    /// Missing messages per folder after its last listing.
    private var missingByFolder: [String: Int] = [:]
    /// History still waiting after the last pass (and within the budget).
    private var historyPending = false
    /// Messages too large to download, per folder: reported, never retried in a loop.
    private var tooLargeByFolder: [String: Set<UInt32>] = [:]

    public private(set) var progress = SyncProgress() {
        didSet { if progress != oldValue { continuation.yield(progress) } }
    }

    public init(account: MailAccountID, connector: any MailboxConnector, store: MailStore,
                options: SyncOptions = SyncOptions(), log: MailLog = .disabled) {
        self.account = account
        self.connector = connector
        self.store = store
        self.options = options
        self.log = log
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    // MARK: - Control

    /// Starts syncing and keeping up, until ``stop()``. Starting a running sync does nothing.
    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    /// Stops syncing and waits until the connection is closed. Whatever was stored stays.
    public func stop() async {
        guard let loop else { return }
        self.loop = nil
        loop.cancel()
        await loop.value
        progress.activity = .stopped
    }

    /// Syncs now: ends the current wait and starts a new pass.
    public func syncNow() async {
        let wasRunning = loop != nil
        await stop()
        if wasRunning { start() }
    }

    /// The folder to wait on (the one the person is looking at); `nil` for the inbox.
    public func setActiveFolder(_ folder: String?) async {
        guard folder != activeFolder else { return }
        activeFolder = folder
        // A wait on the old folder only ends with its timeout, so start over on the new one.
        if loop != nil { await syncNow() }
    }

    /// One complete sync in a fresh session: every folder, all history within the budget.
    /// For tests and command-line use; the app uses ``start()``.
    public func syncOnce() async throws {
        try await connector.withSession { session in
            try await self.passUntilHistoryDone(session)
        }
    }

    // MARK: - The loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            progress.activity = .connecting
            do {
                try await connector.withSession { session in
                    try await self.keepUp(session, onPass: { failures = 0 })
                }
            } catch {
                if Task.isCancelled { break }
                if case MailProviderError.authenticationFailed(let reason) = error {
                    log.warning("sync", "\(account): sign-in refused; stopping until the password is updated")
                    progress.activity = .signInFailed(reason: reason)
                    loop = nil
                    return
                }
                failures += 1
                let delay = options.reconnect.delay(beforeRetry: failures, random: Double.random(in: 0..<1))
                let reason = (error as? MailProviderError)?.description ?? String(describing: error)
                log.warning("sync", "\(account): \(reason); retrying in \(delay)")
                progress.activity = .waitingToRetry(reason: reason, retryAt: Date().addingTimeInterval(Self.seconds(delay)))
                do { try await Task.sleep(for: delay) } catch { break }
            }
        }
        progress.activity = .stopped
    }

    /// A pass, then waiting on the active folder; repeat. Returns only by throwing.
    private func keepUp(_ session: any MailboxSession, onPass: () -> Void) async throws {
        try await pass(session)
        onPass()
        while true {
            try Task.checkCancellation()
            if historyPending {
                try await pass(session)
                continue
            }
            let folder = activeFolder ?? inboxName()
            progress.activity = .watching(folder: displayName(folder))
            let event = try await session.waitForChanges(in: folder, timeout: options.idleTimeout)
            try Task.checkCancellation()
            switch event {
            case .changed:
                log.debug("sync", "\(folder) changed")
                try await syncFolders([folder], session, includeHistory: false)
            case .timedOut:
                try await pass(session)
            }
        }
    }

    private func passUntilHistoryDone(_ session: any MailboxSession) async throws {
        repeat { try await pass(session) } while historyPending
    }

    // MARK: - A pass

    /// Lists the folders, then syncs them all.
    private func pass(_ session: any MailboxSession) async throws {
        let remote = try await session.listFolders().filter(\.isSelectable)
        let ordered = SyncPlanner.order(remote)
        let removed = try await store.replaceSyncedFolders(
            ordered.map { SyncedFolder(name: $0.id, path: $0.path, role: $0.role?.rawValue) }, account: account)
        for name in removed {
            log.info("sync", "folder \(name) is gone at the provider; its messages stay stored")
            missingByFolder[name] = nil
            tooLargeByFolder[name] = nil
        }
        progress.folders = try await store.syncedFolders(account: account)
        try await syncFolders(ordered.map(\.id), session, includeHistory: true)
        progress.lastCompletedPass = Date()
    }

    /// New mail in every folder first, then flags and removals, then history.
    private func syncFolders(_ names: [String], _ session: any MailboxSession, includeHistory: Bool) async throws {
        var plans: [(folder: String, uidValidity: UInt32, plan: SyncPlanner.FolderPlan, serverCount: Int)] = []
        for name in names {
            try Task.checkCancellation()
            do {
                guard let prepared = try await prepare(name, session) else { continue }
                plans.append(prepared)
            } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
                // One folder the server will not open (no permission, removed meanwhile) must not
                // stop the others.
                log.warning("sync", "skipping \(name): \(error)")
            }
        }

        for entry in plans {
            progress.activity = .importing(folder: displayName(entry.folder))
            let result = try await importMessages(entry.plan.recent, folder: entry.folder, uidValidity: entry.uidValidity,
                                                  session, countsAgainstBudget: false)
            // Checkpoint after durable writes: every recent UID is stored now (or too large to be).
            try await store.saveCursor(folder: entry.folder, uidValidity: entry.uidValidity, highestUID: entry.plan.highestUID,
                                       historyComplete: entry.plan.history.isEmpty, serverCount: entry.serverCount, account: account)
            missingByFolder[entry.folder] = entry.plan.history.count + entry.plan.recent.count - result.stored - result.tooLarge
            updateRemaining()
        }

        for entry in plans {
            progress.activity = .checking(folder: displayName(entry.folder))
            try await syncFlags(entry.folder, uidValidity: entry.uidValidity, session)
        }

        if includeHistory {
            var allowance = options.historyPerPass
            historyPending = false
            progress.historyPausedForBudget = false
            for entry in plans where !entry.plan.history.isEmpty {
                guard allowance > 0 else { historyPending = true; break }
                let slice = Array(entry.plan.history.prefix(allowance))
                progress.activity = .importing(folder: displayName(entry.folder))
                let result = try await importMessages(slice, folder: entry.folder, uidValidity: entry.uidValidity,
                                                      session, countsAgainstBudget: true)
                allowance -= slice.count
                missingByFolder[entry.folder] = entry.plan.history.count - result.stored - result.tooLarge
                updateRemaining()
                if result.stored + result.tooLarge == entry.plan.history.count {
                    try await store.saveCursor(folder: entry.folder, uidValidity: entry.uidValidity, highestUID: entry.plan.highestUID,
                                               historyComplete: true, serverCount: entry.serverCount, account: account)
                } else if !progress.historyPausedForBudget {
                    historyPending = true
                }
                if progress.historyPausedForBudget { break }
            }
        }
        progress.folders = try await store.syncedFolders(account: account)
    }

    /// Lists a folder, handles a UIDVALIDITY reset and removals, and plans the imports.
    private func prepare(_ name: String, _ session: any MailboxSession) async throws
        -> (folder: String, uidValidity: UInt32, plan: SyncPlanner.FolderPlan, serverCount: Int)? {
        let listing = try await session.listing(of: name)
        let uidValidity = listing.status.uidValidity
        // A changed UIDVALIDITY voids every UID on record for the folder (RFC 9051 2.3.1.1). The
        // messages stay; re-listing finds them again and reconciliation re-maps them.
        let orphaned = try await store.updateUIDValidity(uidValidity, mailbox: name, account: account)
        let saved = try await store.syncedFolders(account: account).first { $0.name == name }
        let isReset = saved?.uidValidity != nil && saved?.uidValidity != uidValidity
        if isReset {
            log.warning("sync", "\(name): UIDVALIDITY changed; re-mapping \(orphaned.count) stored messages")
            tooLargeByFolder[name] = nil
        }
        let cursor = saved?.uidValidity == uidValidity ? saved?.highestUID : nil
        let known = try await store.knownUIDs(mailbox: name, uidValidity: uidValidity, account: account)
        let plan = SyncPlanner.plan(serverUIDs: listing.uids, known: Set(known.keys), cursor: cursor,
                                    recentLimit: options.recentPerFolder)
        for uid in plan.gone {
            // Expunged or moved at the provider: the location goes, the stored message stays.
            try await store.forget(RemoteLocation(mailbox: name, uidValidity: uidValidity, uid: uid), account: account)
        }
        if !plan.gone.isEmpty { log.info("sync", "\(name): \(plan.gone.count) messages left the folder") }
        return (name, uidValidity, plan, listing.uids.count)
    }

    private struct ImportResult {
        /// Imported, or matched to a stored message.
        var stored = 0
        /// Too large to download; they stay at the provider.
        var tooLarge = 0
    }

    /// Downloads and stores messages, in batches, in the order given (newest first).
    private func importMessages(_ uids: [UInt32], folder: String, uidValidity: UInt32,
                                _ session: any MailboxSession, countsAgainstBudget: Bool) async throws -> ImportResult {
        var result = ImportResult()
        for chunk in SyncPlanner.chunks(uids, of: options.summaryBatch) {
            try Task.checkCancellation()
            let ids = chunk.map { RemoteMessageID(folder: folder, uidValidity: uidValidity, uid: $0) }
            // Summaries give sizes for batching; keep the order asked for.
            let byUID = Dictionary(try await session.summaries(of: ids).map { ($0.id.uid, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = chunk.compactMap { byUID[$0] }
            let (batches, tooLarge) = SyncPlanner.batches(ordered, maxMessages: options.bodyBatchMessages,
                                                         maxBytes: options.bodyBatchBytes, maxMessageSize: session.maximumMessageSize)
            if !tooLarge.isEmpty {
                log.warning("sync", "\(folder): \(tooLarge.count) messages are too large to download and stay at the provider")
                tooLargeByFolder[folder, default: []].formUnion(tooLarge.map(\.id.uid))
                progress.skippedTooLarge = tooLargeByFolder.values.reduce(0) { $0 + $1.count }
                result.tooLarge += tooLarge.count
            }
            for batch in batches {
                try Task.checkCancellation()
                if countsAgainstBudget {
                    let next = Int64(batch.reduce(0) { $0 + ($1.size ?? 0) })
                    let imported = try await store.importedBytes(account: account)
                    guard SyncPlanner.budgetAllows(alreadyImported: imported, next: next, budget: options.historyBudgetBytes) else {
                        log.info("sync", "history paused at the storage budget")
                        progress.historyPausedForBudget = true
                        return result
                    }
                }
                let fetched = try await session.fetchMessages(batch.map(\.id))
                let byID = Dictionary(fetched.map { ($0.summary.id, $0) }, uniquingKeysWith: { a, _ in a })
                for summary in batch {
                    guard let message = byID[summary.id] else { continue } // expunged meanwhile
                    try await save(message)
                    result.stored += 1
                    progress.imported += 1
                    progress.remaining = max(0, progress.remaining - 1)
                }
            }
        }
        return result
    }

    /// Stores one fetched message, or records its location on the stored message it is.
    private func save(_ message: FetchedMessage) async throws {
        let id = message.summary.id
        let location = RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid)
        let flags = Self.flags(message.summary.flags)
        if let existing = try await store.localID(at: location, account: account) {
            try await store.setFlags([existing: flags], account: account)
            return
        }
        // The same message seen before (a move, a copy, a UIDVALIDITY reset): same bytes, same
        // message. Message-ID or a fingerprint alone is only a signal, never enough to merge.
        for candidate in try await store.reconciliationCandidates(for: message.rawMessage, account: account) {
            if let original = try? await store.originalData(of: candidate), original == message.rawMessage {
                try await store.record(location, for: candidate, account: account)
                try await store.setFlags([candidate: flags], account: account)
                log.debug("sync", "\(id) matched a stored message")
                return
            }
        }
        let result = try await store.ingest(message.rawMessage, account: account, remote: location,
                                            receivedAt: message.summary.internalDate ?? Date())
        try await store.setFlags([result.id: flags], account: account)
        try await store.addImportedBytes(Int64(message.rawMessage.count), account: account)
    }

    /// Brings stored flags in line with the provider's, for every stored message in the folder.
    private func syncFlags(_ folder: String, uidValidity: UInt32, _ session: any MailboxSession) async throws {
        let known = try await store.knownUIDs(mailbox: folder, uidValidity: uidValidity, account: account)
        guard !known.isEmpty else { return }
        for chunk in SyncPlanner.chunks(known.keys.sorted(), of: options.summaryBatch) {
            try Task.checkCancellation()
            let remote = try await session.flags(of: chunk.map { RemoteMessageID(folder: folder, uidValidity: uidValidity, uid: $0) })
            let ids = chunk.compactMap { known[$0] }
            let local = try await store.flags(of: ids, account: account)
            var changed: [MailMessageID: MailMessageFlags] = [:]
            for (remoteID, remoteFlags) in remote {
                guard let id = known[remoteID.uid] else { continue }
                let flags = Self.flags(remoteFlags)
                if local[id] != flags { changed[id] = flags }
            }
            if !changed.isEmpty {
                try await store.setFlags(changed, account: account)
                log.debug("sync", "\(folder): flags changed on \(changed.count) messages")
            }
        }
    }

    // MARK: - Helpers

    private func updateRemaining() {
        progress.remaining = missingByFolder.values.reduce(0, +)
    }

    private func inboxName() -> String {
        progress.folders.first { $0.role == FolderRole.inbox.rawValue }?.name ?? "INBOX"
    }

    private func displayName(_ folder: String) -> String {
        progress.folders.first { $0.name == folder }?.displayName ?? folder
    }

    static func flags(_ flags: MessageFlags) -> MailMessageFlags {
        MailMessageFlags(seen: flags.seen, answered: flags.answered, flagged: flags.flagged, draft: flags.draft,
                         keywords: Array(flags.keywords))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension MailProviderError {
    var authenticationFailedReason: String? {
        if case .authenticationFailed(let reason) = self { return reason }
        return nil
    }
}
