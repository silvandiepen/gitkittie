import Foundation
import MailCore
import MailProvider
import MailStore

/// Keeps one account's mail in the store in step with the provider (GKM-011; Architecture.md,
/// Multi-device sync).
///
/// - **Progressive.** Each pass imports every folder's new mail first (on a first sync, the
///   newest ``SyncOptions/recentPerFolder`` messages), newest first, then flags and removals,
///   then a slice of history, newest first, within the storage budget and the history window
///   (``SyncOptions/historyDays``). Between slices it checks for new mail again, so a long
///   history import never hides today's mail.
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
    /// History left out by the window, per folder, after its last listing (GKM-039).
    private var olderByFolder: [String: Int] = [:]
    /// What each folder's window searches found, so a pass searches only for what it has not
    /// sorted yet.
    private var windows: [String: WindowSearch] = [:]
    /// When every folder's flags were last checked.
    private var lastFlagCheck: ContinuousClock.Instant?
    /// Folders this pass could not list (no permission, removed meanwhile): a deletion is not
    /// confirmed while one is unlisted, since the message may be there.
    private var unlistedFolders: Set<String> = []
    /// Folders the account chose not to sync (MAIL-093), as of the last listing.
    private var notSyncedFolders: Set<String> = []

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
        progress.historyDays = options.historyDays
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
                try await pass(session, continuingHistory: true)
                continue
            }
            // A folder that doesn't sync is never waited on.
            let folder = activeFolder.flatMap { notSyncedFolders.contains($0) ? nil : $0 } ?? inboxName()
            progress.activity = .watching(folder: displayName(folder))
            let event = try await session.waitForChanges(in: folder, timeout: options.idleTimeout)
            try Task.checkCancellation()
            switch event {
            case .changed:
                log.debug("sync", "\(folder) changed")
                try await syncFolders([folder], session, includeHistory: false, checkFlags: true)
            case .timedOut:
                try await pass(session)
            }
        }
    }

    private func passUntilHistoryDone(_ session: any MailboxSession) async throws {
        try await pass(session)
        while historyPending { try await pass(session, continuingHistory: true) }
    }

    // MARK: - A pass

    /// Lists the folders, then syncs them all. A pass that only continues a history import
    /// checks flags at most every ``SyncOptions/flagCheckInterval``.
    private func pass(_ session: any MailboxSession, continuingHistory: Bool = false) async throws {
        let remote = try await session.listFolders().filter(\.isSelectable)
        let ordered = SyncPlanner.order(remote)
        let removed = try await store.replaceSyncedFolders(FolderEditor.recorded(ordered, settings: options.mailboxes), account: account)
        for name in removed {
            log.info("sync", "folder \(name) is gone at the provider; its messages stay stored")
            missingByFolder[name] = nil
            tooLargeByFolder[name] = nil
            olderByFolder[name] = nil
            windows[name] = nil
        }
        progress.folders = try await store.syncedFolders(account: account)
        let flagsDue = lastFlagCheck.map { ContinuousClock.now - $0 >= options.flagCheckInterval } ?? true
        unlistedFolders = []
        // Every folder is on record; only those the account syncs are opened (MAIL-093).
        let synced = ordered.filter { options.mailboxes.syncs($0.id, detectedRole: $0.role?.rawValue) }
        notSyncedFolders = Set(ordered.map(\.id)).subtracting(synced.map(\.id))
        for name in notSyncedFolders.sorted() {
            // A move this device made into a folder that doesn't sync is never listed there, so it
            // settles now instead of waiting for a listing.
            try await store.settleAwaitingActions(mailbox: name, listedAt: Date(), account: account)
        }
        try await syncFolders(synced.map(\.id), session, includeHistory: true, checkFlags: !continuingHistory || flagsDue)
        try await completePinned(session)
        try await reviewDeletions(session)
        progress.lastCompletedPass = Date()
    }

    // MARK: - Deleted at the provider (MAIL-075)

    /// After a pass over every folder: a message noticed leaving its last folder that no folder
    /// listing brought back is deleted at the provider, unless a folder with mail this device has
    /// not downloaded (history left out by the window or the budget, too large, not reached yet)
    /// has it: those folders are searched for its Message-ID first, or, without one, for its
    /// sender and day, compared by size and header (``DeletionProbe``, MAIL-104); when that cannot
    /// tell, it is not marked and goes behind the others, checked again after a back-off
    /// (``SyncOptions/undecidedDeletionBackoff``, MAIL-105), so candidates that can't be decided
    /// never use up a pass's checks ahead of newer ones. Then, with
    /// ``SyncOptions/removesMailDeletedElsewhere``, the local copies go.
    private func reviewDeletions(_ session: any MailboxSession) async throws {
        guard unlistedFolders.isEmpty else { return }
        let candidates = try await store.deletionCandidates(account: account)
        if !candidates.isEmpty {
            // A folder that doesn't sync may have the message: it is searched like one whose mail
            // is not all here.
            let incomplete = progress.folders.map(\.name).filter { name in
                notSyncedFolders.contains(name) || (missingByFolder[name] ?? 0) > 0 || (olderByFolder[name] ?? 0) > 0 || !(tooLargeByFolder[name]?.isEmpty ?? true)
            }
            var confirmed: [DeletionCandidate] = []
            var checks = options.deletionChecksPerPass
            let now = Date()
            // In the store's order: never undecided first, then the least recently checked.
            for candidate in candidates {
                try Task.checkCancellation()
                guard !incomplete.isEmpty else { confirmed.append(candidate); continue }
                guard checks > 0 else { continue }
                guard Self.isDue(candidate, at: now, backoff: options.undecidedDeletionBackoff) else { continue }
                checks -= 1
                var found: Bool? = false
                if let messageID = candidate.messageID {
                    for folder in incomplete where found == false {
                        found = !(try await session.search(messageIDHeader: messageID, in: folder)).isEmpty
                    }
                } else {
                    let probe: DeletionProbe
                    do {
                        probe = try await DeletionProbe(store.message(candidate.id))
                    } catch {
                        // Not readable here now: nothing to look for it by, so it is not marked.
                        log.warning("sync", "could not read a message that left its last folder (\(error)); not marking it")
                        try await store.recordUndecidedDeletionCheck(of: candidate.id, account: account, now: now)
                        continue
                    }
                    found = try await probe.find(in: incomplete, session)
                }
                switch found {
                case true?: try await store.dismissDeletion(of: candidate.id, account: account)
                case false?: confirmed.append(candidate)
                case nil:
                    log.info("sync", "a message without a Message-ID left its last folder; not sure it is gone, checking again later")
                    try await store.recordUndecidedDeletionCheck(of: candidate.id, account: account, now: now)
                }
            }
            if !confirmed.isEmpty {
                try await store.confirmDeletions(confirmed, account: account)
                log.info("sync", "\(confirmed.count) messages were deleted at the provider; kept here and marked")
            }
        }
        if options.removesMailDeletedElsewhere {
            let removed = try await store.removeMailDeletedAtProvider(account: account)
            if !removed.isEmpty {
                progress.removedDeletedElsewhere += removed.count
                log.info("sync", "removed \(removed.count) messages deleted at the provider (Remove mail deleted elsewhere)")
            }
        }
        progress.deletedAtProvider = try await store.deletedAtProvider(account: account).count
    }

    /// Whether a candidate is to be checked at the provider now: always when no check has failed
    /// to decide it, else once its back-off has passed since the last one, the lower bound of
    /// `backoff` doubled for each undecided check after the first, at most the upper bound.
    /// A last check in the future (the clock was set back) is due at once.
    static func isDue(_ candidate: DeletionCandidate, at now: Date, backoff: ClosedRange<Duration>) -> Bool {
        guard let checkedAt = candidate.checkedAt, candidate.undecidedChecks > 0 else { return true }
        let doublings = min(candidate.undecidedChecks - 1, 32)
        let wait = min(seconds(backoff.lowerBound) * Double(1 << doublings), seconds(backoff.upperBound))
        let elapsed = now.timeIntervalSince(checkedAt)
        // A clock set back must not make it wait longer than the back-off.
        return elapsed < 0 || elapsed >= wait
    }

    /// New mail in every folder first, then flags and removals, then history.
    private func syncFolders(_ names: [String], _ session: any MailboxSession, includeHistory: Bool,
                             checkFlags: Bool) async throws {
        var plans: [PreparedFolder] = []
        for name in names {
            try Task.checkCancellation()
            do {
                guard let prepared = try await prepare(name, session) else { continue }
                plans.append(prepared)
            } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
                // One folder the server will not open (no permission, removed meanwhile) must not
                // stop the others.
                log.warning("sync", "skipping \(name): \(error)")
                unlistedFolders.insert(name)
            }
        }

        for entry in plans {
            progress.activity = .importing(folder: displayName(entry.folder))
            let result = try await importMessages(entry.plan.recent, folder: entry.folder, uidValidity: entry.uidValidity,
                                                  session, countsAgainstBudget: false)
            // Checkpoint after durable writes: every recent UID is stored now (or too large to be).
            try await store.saveCursor(folder: entry.folder, uidValidity: entry.uidValidity, highestUID: entry.plan.highestUID,
                                       historyComplete: entry.plan.history.isEmpty && entry.plan.older.isEmpty,
                                       serverCount: entry.serverCount, account: account)
            missingByFolder[entry.folder] = entry.plan.history.count + entry.plan.recent.count - result.stored - result.tooLarge
            updateRemaining()
        }

        if checkFlags { try await syncFlags(of: plans, session, recordCheck: includeHistory) }
        for entry in plans {
            // Moves this device made that the provider did not report ids for are mapped by now
            // (the folder was listed after them), or did not land there: either way they settle.
            try await store.settleAwaitingActions(mailbox: entry.folder, listedAt: entry.listedAt, account: account)
        }

        if includeHistory {
            // A slice ends at a count or a time (GKM-038), whichever comes first; then the next
            // pass lists the folders again and imports new mail before more history.
            var allowance = options.historyPerPass
            let sliceEnds = ContinuousClock.now + options.historySlice
            historyPending = false
            progress.historyPausedForBudget = false
            for entry in plans where !entry.plan.history.isEmpty {
                guard allowance > 0, ContinuousClock.now < sliceEnds else { historyPending = true; break }
                let slice = Array(entry.plan.history.prefix(allowance))
                progress.activity = .importing(folder: displayName(entry.folder))
                let result = try await importMessages(slice, folder: entry.folder, uidValidity: entry.uidValidity,
                                                      session, countsAgainstBudget: true, until: sliceEnds)
                allowance -= result.stored + result.tooLarge
                missingByFolder[entry.folder] = entry.plan.history.count - result.stored - result.tooLarge
                updateRemaining()
                if result.stored + result.tooLarge == entry.plan.history.count {
                    try await store.saveCursor(folder: entry.folder, uidValidity: entry.uidValidity, highestUID: entry.plan.highestUID,
                                               historyComplete: entry.plan.older.isEmpty, serverCount: entry.serverCount,
                                               account: account)
                } else if !progress.historyPausedForBudget {
                    historyPending = true
                }
                if progress.historyPausedForBudget { break }
            }
            // The history is done (or paused): bring flags up to date before waiting for changes.
            if !checkFlags, !historyPending { try await syncFlags(of: plans, session, recordCheck: true) }
        }
        progress.folders = try await store.syncedFolders(account: account)
    }

    private struct PreparedFolder {
        var folder: String
        var uidValidity: UInt32
        var plan: SyncPlanner.FolderPlan
        var serverCount: Int
        /// HIGHESTMODSEQ at the listing, when the server has CONDSTORE.
        var highestModSeq: UInt64?
        var listedAt: Date
    }

    /// Lists a folder, handles a UIDVALIDITY reset and removals, and plans the imports.
    private func prepare(_ name: String, _ session: any MailboxSession) async throws -> PreparedFolder? {
        let listedAt = Date()
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
        let known = Set(try await store.knownUIDs(mailbox: name, uidValidity: uidValidity, account: account).keys)
        var older: Set<UInt32>?
        if let days = options.historyDays {
            let start = SyncPlanner.windowStart(days: days, now: Date())
            older = try await olderThanWindow(name, uidValidity: uidValidity, start: start, serverUIDs: listing.uids,
                                              known: known, cursor: cursor, session)
        }
        let plan = SyncPlanner.plan(serverUIDs: listing.uids, known: known, cursor: cursor,
                                    recentLimit: options.recentPerFolder, olderThanWindow: older)
        olderByFolder[name] = plan.older.count
        progress.olderNotDownloaded = olderByFolder.values.reduce(0, +)
        if !plan.older.isEmpty, plan.older.count != windows[name]?.reportedOlder {
            log.info("sync", "\(name): \(plan.older.count) messages received before the history window stay at the provider")
            windows[name]?.reportedOlder = plan.older.count
        }
        for uid in plan.gone {
            // Expunged or moved at the provider: the location goes, the stored message stays.
            try await store.forget(RemoteLocation(mailbox: name, uidValidity: uidValidity, uid: uid), account: account)
        }
        if !plan.gone.isEmpty { log.info("sync", "\(name): \(plan.gone.count) messages left the folder") }
        return PreparedFolder(folder: name, uidValidity: uidValidity, plan: plan, serverCount: listing.uids.count,
                              highestModSeq: listing.status.highestModSeq, listedAt: listedAt)
    }

    /// One folder's window searches (GKM-039): which UIDs were received before the window and
    /// which within it, at one UIDVALIDITY.
    private struct WindowSearch {
        var uidValidity: UInt32
        /// The window's first day when `within` was searched.
        var start: Date
        var within: Set<UInt32>
        /// Received before a window start no later than today's: still before it, since the
        /// window only moves forward and a UID's received date never changes.
        var older: Set<UInt32>
        var reportedOlder = 0
    }

    /// The UIDs among the folder's history candidates that were received before `start`.
    /// Searches the server (UID SEARCH SINCE) only for candidates no earlier search sorted.
    private func olderThanWindow(_ name: String, uidValidity: UInt32, start: Date, serverUIDs: [UInt32], known: Set<UInt32>,
                                 cursor: UInt32?, _ session: any MailboxSession) async throws -> Set<UInt32> {
        let candidates = SyncPlanner.historyCandidates(serverUIDs: serverUIDs, known: known, cursor: cursor)
        var search = windows[name].flatMap { $0.uidValidity == uidValidity ? $0 : nil }
            ?? WindowSearch(uidValidity: uidValidity, start: start, within: [], older: [])
        if search.start != start {
            // A later day: what was within the window may have left it.
            search.start = start
            search.within = []
        }
        let unsorted = candidates.filter { !search.older.contains($0) && !search.within.contains($0) }
        if !unsorted.isEmpty {
            let within = Set(try await session.uids(in: name, uidValidity: uidValidity, receivedSince: start))
            search.within = within
            search.older.formUnion(unsorted.lazy.filter { !within.contains($0) })
        }
        // Only what is still at the provider and not stored matters; keep the sets that small.
        let wanted = Set(candidates)
        search.older.formIntersection(wanted)
        search.within.formIntersection(wanted)
        windows[name] = search
        return search.older
    }

    private struct ImportResult {
        /// Imported, or matched to a stored message.
        var stored = 0
        /// Too large to download; they stay at the provider.
        var tooLarge = 0
    }

    /// Downloads and stores messages, in batches, in the order given (newest first). With a
    /// deadline (`until`) it stops between batches once the deadline passes.
    ///
    /// Fetching and storing overlap (GKM-038): while one batch is written by the store (an
    /// actor of its own), the next is already being downloaded. At most one batch is being
    /// stored at a time and the batches are stored in order; whatever stops the import, the
    /// batch being stored is finished before this returns or throws, so a cursor saved after it
    /// covers only what is durable.
    ///
    /// Messages larger than ``SyncOptions/onDemandThreshold`` are looked at part by part:
    /// their large attachments stay at the provider (GKM-036).
    private func importMessages(_ uids: [UInt32], folder: String, uidValidity: UInt32, _ session: any MailboxSession,
                                countsAgainstBudget: Bool, until deadline: ContinuousClock.Instant? = nil) async throws -> ImportResult {
        var result = ImportResult()
        var storing: StoringBatch?
        do {
            chunks: for chunk in SyncPlanner.chunks(uids, of: options.summaryBatch) {
                try Task.checkCancellation()
                if let deadline, ContinuousClock.now >= deadline { break }
                let ids = chunk.map { RemoteMessageID(folder: folder, uidValidity: uidValidity, uid: $0) }
                // Summaries give sizes for batching; keep the order asked for.
                let byUID = Dictionary(try await session.summaries(of: ids).map { ($0.id.uid, $0) }, uniquingKeysWith: { a, _ in a })
                let ordered = chunk.compactMap { byUID[$0] }
                let threshold = options.onDemandThreshold
                let large = threshold.map { limit in ordered.filter { ($0.size ?? 0) > limit } } ?? []
                let whole = large.isEmpty ? ordered : ordered.filter { ($0.size ?? 0) <= threshold! }
                let (batches, tooLarge) = SyncPlanner.batches(whole, maxMessages: options.bodyBatchMessages,
                                                             maxBytes: options.bodyBatchBytes, maxMessageSize: session.maximumMessageSize)
                reportTooLarge(tooLarge, folder: folder, into: &result)
                for batch in batches {
                    try Task.checkCancellation()
                    if let deadline, ContinuousClock.now >= deadline { break chunks }
                    let next = Int64(batch.reduce(0) { $0 + ($1.size ?? 0) })
                    if countsAgainstBudget, options.historyBudgetBytes != nil {
                        // The budget is checked against what is actually stored: the batch in the
                        // store is finished first (no overlap while a budget applies), because a
                        // server's RFC822.SIZE is only an estimate of the bytes it sends.
                        try await settle(&storing, into: &result, folder: folder)
                        let imported = try await store.importedBytes(account: account)
                        guard SyncPlanner.budgetAllows(alreadyImported: imported, next: next, budget: options.historyBudgetBytes) else {
                            log.info("sync", "history paused at the storage budget")
                            progress.historyPausedForBudget = true
                            return result
                        }
                    }
                    let fetched = try await session.fetchMessages(batch.map(\.id))
                    let byID = Dictionary(fetched.map { ($0.summary.id, $0) }, uniquingKeysWith: { a, _ in a })
                    // Stored as one batch: one flush per directory and one commit per database for
                    // the lot, instead of several per message (GKM-035).
                    let messages = batch.compactMap { byID[$0.id] }.map(Self.synced) // missing: expunged meanwhile
                    try await settle(&storing, into: &result, folder: folder)
                    let store = self.store
                    let account = self.account
                    storing = StoringBatch(task: Task { try await store.storeSynced(messages, account: account) })
                    if !options.pipelineStores { try await settle(&storing, into: &result, folder: folder) }
                }
                if !large.isEmpty {
                    try await settle(&storing, into: &result, folder: folder)
                    let paused = try await importPartially(large, folder: folder, session, countsAgainstBudget: countsAgainstBudget,
                                                           into: &result)
                    if paused {
                        log.info("sync", "history paused at the storage budget")
                        progress.historyPausedForBudget = true
                        return result
                    }
                }
            }
            try await settle(&storing, into: &result, folder: folder)
        } catch {
            // Never leave a batch unfinished or uncounted: the store finishes it (durable or not),
            // and what it stored is counted before the error goes up.
            try? await settle(&storing, into: &result, folder: folder)
            throw error
        }
        return result
    }

    /// A fetched batch the store is writing while the next one downloads.
    private struct StoringBatch {
        var task: Task<[SyncedOutcome], any Error>
    }

    /// Waits for the batch being stored, if any, and counts it.
    private func settle(_ storing: inout StoringBatch?, into result: inout ImportResult, folder: String) async throws {
        guard let batch = storing else { return }
        storing = nil
        let outcomes = try await batch.task.value
        for outcome in outcomes {
            if case .matched(let id) = outcome { log.debug("sync", "\(folder): a fetched message matched stored \(id)") }
        }
        result.stored += outcomes.count
        progress.imported += outcomes.count
        progress.remaining = max(0, progress.remaining - outcomes.count)
    }

    private func reportTooLarge(_ tooLarge: [RemoteMessageSummary], folder: String, into result: inout ImportResult) {
        guard !tooLarge.isEmpty else { return }
        log.warning("sync", "\(folder): \(tooLarge.count) messages are too large to download and stay at the provider")
        tooLargeByFolder[folder, default: []].formUnion(tooLarge.map(\.id.uid))
        progress.skippedTooLarge = tooLargeByFolder.values.reduce(0) { $0 + $1.count }
        result.tooLarge += tooLarge.count
    }

    /// Stores large messages without their large attachments (GKM-036): their structure first,
    /// then the header, every MIME header and the parts at or below the threshold; the rest is
    /// fetched when opened or pinned. A message whose structure a partial copy cannot be made
    /// of, or that may be a message already stored whole, is fetched whole.
    /// Returns true when the history budget stopped it (only when `countsAgainstBudget`): each
    /// message is weighed by what storing it adds, against what is already stored.
    private func importPartially(_ summaries: [RemoteMessageSummary], folder: String, _ session: any MailboxSession,
                                 countsAgainstBudget: Bool, into result: inout ImportResult) async throws -> Bool {
        let budget = countsAgainstBudget ? options.historyBudgetBytes : nil
        func allows(_ next: Int) async throws -> Bool {
            guard let budget else { return true }
            let imported = try await store.importedBytes(account: account)
            return SyncPlanner.budgetAllows(alreadyImported: imported, next: Int64(next), budget: budget)
        }
        let threshold = options.onDemandThreshold ?? 0
        let structures = try await session.bodyStructures(of: summaries.map(\.id))
        var whole: [RemoteMessageSummary] = []
        var stored = 0
        for summary in summaries {
            try Task.checkCancellation()
            guard let remote = structures[summary.id] else { continue } // expunged meanwhile
            guard let message = try await Self.partialCopy(of: summary, structure: remote, threshold: threshold, session, log: log) else {
                whole.append(summary)
                continue
            }
            guard try await allows(message.storedSize) else { return true }
            // One at a time: each is weighed against the budget by what is stored before it.
            let outcome = try await store.storeSyncedPartials([message], account: account).first ?? nil
            guard outcome != nil else { whole.append(summary); continue } // compare with a stored original
            stored += 1
            result.stored += 1
            progress.imported += 1
            progress.remaining = max(0, progress.remaining - 1)
        }
        if stored > 0 { log.debug("sync", "\(folder): \(stored) large messages stored without their large attachments") }
        guard !whole.isEmpty else { return false }
        let (batches, tooLarge) = SyncPlanner.batches(whole, maxMessages: options.bodyBatchMessages, maxBytes: options.bodyBatchBytes,
                                                     maxMessageSize: session.maximumMessageSize)
        reportTooLarge(tooLarge, folder: folder, into: &result)
        for batch in batches {
            guard try await allows(batch.reduce(0) { $0 + ($1.size ?? 0) }) else { return true }
            let fetched = try await session.fetchMessages(batch.map(\.id))
            let outcomes = try await store.storeSynced(fetched.map(Self.synced), account: account)
            result.stored += outcomes.count
            progress.imported += outcomes.count
            progress.remaining = max(0, progress.remaining - outcomes.count)
        }
        return false
    }

    /// A large message without its large attachments (GKM-036): its header, every MIME header
    /// and the parts at or below `threshold`. Nil when it must be fetched whole: its structure
    /// is not one a partial copy can be made of, or the server left out sections (no MIME
    /// headers, say), so the copy would not be faithful.
    static func partialCopy(of summary: RemoteMessageSummary, structure remote: RemoteBodyPart, threshold: Int,
                            _ session: any MailboxSession, log: MailLog) async throws -> SyncedPartialMessage? {
        let structure = part(remote)
        guard let sections = PartialPlan.sections(of: structure, threshold: threshold) else { return nil }
        let fetched = try await session.fetchSections(sections, of: summary.id)
        guard let header = fetched["HEADER"], sections.allSatisfy({ fetched[$0] != nil }),
              PartialPlan.isConsistent(structure, sections: fetched) else {
            log.info("sync", "\(summary.id.folder): the server left out sections of a large message; fetching it whole")
            return nil
        }
        var parts = fetched
        parts["HEADER"] = nil
        let id = summary.id
        return SyncedPartialMessage(
            header: header, structure: structure, sections: parts, size: summary.size ?? 0,
            remote: RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid),
            receivedAt: summary.internalDate ?? Date(), flags: flags(summary.flags))
    }

    /// The provider's part tree as the store keeps it.
    static func part(_ remote: RemoteBodyPart) -> MessagePart {
        MessagePart(section: remote.section, mediaType: remote.mediaType, boundary: remote.boundary, encoding: remote.encoding,
                    size: remote.size, fileName: remote.fileName, disposition: remote.disposition, contentID: remote.contentID,
                    parts: remote.parts.map(part))
    }

    /// Downloads the whole original of partial messages that a pin covers (GKM-036), a few per
    /// pass, so pinned mail is all here when the connection goes.
    private func completePinned(_ session: any MailboxSession) async throws {
        guard options.onDemandThreshold != nil else { return }
        let pinned = try await store.pinnedPartialMessages(account: account).prefix(options.pinnedPerPass)
        guard !pinned.isEmpty else { return }
        progress.activity = .importing(folder: "pinned messages")
        let completed = try await OnDemandFetcher.complete(Array(pinned), store: store, session: session, log: log)
        if completed > 0 { log.info("sync", "\(completed) pinned messages downloaded for offline") }
    }

    /// A fetched message as the store takes it.
    static func synced(_ message: FetchedMessage) -> SyncedMessage {
        let id = message.summary.id
        return SyncedMessage(eml: message.rawMessage, remote: RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid),
                             receivedAt: message.summary.internalDate ?? Date(), flags: flags(message.summary.flags))
    }

    /// Checks the flags in each folder; `recordCheck` when these are all the account's folders.
    private func syncFlags(of folders: [PreparedFolder], _ session: any MailboxSession, recordCheck: Bool) async throws {
        for entry in folders {
            progress.activity = .checking(folder: displayName(entry.folder))
            try await syncFlags(entry.folder, uidValidity: entry.uidValidity, highestModSeq: entry.highestModSeq, session)
        }
        if recordCheck { lastFlagCheck = ContinuousClock.now }
    }

    /// Brings stored flags in line with the provider's, for every stored message in the folder.
    ///
    /// With CONDSTORE (RFC 7162) only what changed since the folder's checkpointed HIGHESTMODSEQ
    /// is read — nothing at all when the folder is unchanged; the checkpoint is saved after the
    /// flags it covers. Without CONDSTORE, or before the first checkpoint, every stored
    /// message's flags are read (the fallback, which also sets the first checkpoint).
    private func syncFlags(_ folder: String, uidValidity: UInt32, highestModSeq: UInt64?, _ session: any MailboxSession) async throws {
        let known = try await store.knownUIDs(mailbox: folder, uidValidity: uidValidity, account: account)
        if session.capabilities.changeTracking, let highestModSeq,
           let checkpoint = try await store.highestModSeq(folder: folder, uidValidity: uidValidity, account: account) {
            if highestModSeq == checkpoint { return }
            do {
                let changes = try await session.flagChanges(in: folder, uidValidity: uidValidity, since: checkpoint)
                try await applyFlags(changes.flags, known: known)
                try await store.saveHighestModSeq(changes.highestModSeq, folder: folder, uidValidity: uidValidity, account: account)
                log.debug("sync", "\(folder): \(changes.flags.count) flag changes since modseq \(checkpoint)")
                return
            } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
                log.info("sync", "\(folder): CONDSTORE unavailable (\(error)); reading every flag")
            }
        }
        try await syncAllFlags(folder, uidValidity: uidValidity, known: known, session)
        if session.capabilities.changeTracking, let highestModSeq {
            // The listing's value predates the reads, so nothing after it can be missed.
            try await store.saveHighestModSeq(highestModSeq, folder: folder, uidValidity: uidValidity, account: account)
        }
    }

    /// Stores the provider's flags for the stored messages among `remote`.
    private func applyFlags(_ remote: [RemoteMessageID: MailProvider.MessageFlags], known: [UInt32: MailMessageID]) async throws {
        let ids = remote.keys.compactMap { known[$0.uid] }
        guard !ids.isEmpty else { return }
        let local = try await store.flags(of: ids, account: account)
        var changed: [MailMessageID: MailMessageFlags] = [:]
        for (remoteID, remoteFlags) in remote {
            guard let id = known[remoteID.uid] else { continue }
            let flags = Self.flags(remoteFlags)
            if local[id] != flags { changed[id] = flags }
        }
        if !changed.isEmpty { try await store.setFlags(changed, account: account) }
    }

    /// The fallback: every stored message's flags, in batches.
    private func syncAllFlags(_ folder: String, uidValidity: UInt32, known: [UInt32: MailMessageID],
                              _ session: any MailboxSession) async throws {
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

    static func flags(_ flags: MailProvider.MessageFlags) -> MailMessageFlags {
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
