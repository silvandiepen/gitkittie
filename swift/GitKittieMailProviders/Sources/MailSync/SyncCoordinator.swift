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
    /// When every folder's flags were last checked.
    private var lastFlagCheck: ContinuousClock.Instant?

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
                try await pass(session, continuingHistory: true)
                continue
            }
            let folder = activeFolder ?? inboxName()
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
        let removed = try await store.replaceSyncedFolders(
            ordered.map { SyncedFolder(name: $0.id, path: $0.path, role: $0.role?.rawValue) }, account: account)
        for name in removed {
            log.info("sync", "folder \(name) is gone at the provider; its messages stay stored")
            missingByFolder[name] = nil
            tooLargeByFolder[name] = nil
        }
        progress.folders = try await store.syncedFolders(account: account)
        let flagsDue = lastFlagCheck.map { ContinuousClock.now - $0 >= options.flagCheckInterval } ?? true
        try await syncFolders(ordered.map(\.id), session, includeHistory: true, checkFlags: !continuingHistory || flagsDue)
        try await completePinned(session)
        progress.lastCompletedPass = Date()
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
                                               historyComplete: true, serverCount: entry.serverCount, account: account)
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
        let known = try await store.knownUIDs(mailbox: name, uidValidity: uidValidity, account: account)
        let plan = SyncPlanner.plan(serverUIDs: listing.uids, known: Set(known.keys), cursor: cursor,
                                    recentLimit: options.recentPerFolder)
        for uid in plan.gone {
            // Expunged or moved at the provider: the location goes, the stored message stays.
            try await store.forget(RemoteLocation(mailbox: name, uidValidity: uidValidity, uid: uid), account: account)
        }
        if !plan.gone.isEmpty { log.info("sync", "\(name): \(plan.gone.count) messages left the folder") }
        return PreparedFolder(folder: name, uidValidity: uidValidity, plan: plan, serverCount: listing.uids.count,
                              highestModSeq: listing.status.highestModSeq, listedAt: listedAt)
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
                    if countsAgainstBudget {
                        let imported = try await store.importedBytes(account: account) + (storing?.bytes ?? 0)
                        guard SyncPlanner.budgetAllows(alreadyImported: imported, next: next, budget: options.historyBudgetBytes) else {
                            log.info("sync", "history paused at the storage budget")
                            progress.historyPausedForBudget = true
                            try await settle(&storing, into: &result, folder: folder)
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
                    storing = StoringBatch(task: Task { try await store.storeSynced(messages, account: account) }, bytes: next)
                    if !options.pipelineStores { try await settle(&storing, into: &result, folder: folder) }
                }
                if !large.isEmpty {
                    try await settle(&storing, into: &result, folder: folder)
                    try await importPartially(large, folder: folder, session, into: &result)
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
        var bytes: Int64
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
    private func importPartially(_ summaries: [RemoteMessageSummary], folder: String, _ session: any MailboxSession,
                                 into result: inout ImportResult) async throws {
        let threshold = options.onDemandThreshold ?? 0
        let structures = try await session.bodyStructures(of: summaries.map(\.id))
        var partials: [(summary: RemoteMessageSummary, message: SyncedPartialMessage)] = []
        var whole: [RemoteMessageSummary] = []
        for summary in summaries {
            try Task.checkCancellation()
            guard let remote = structures[summary.id] else { continue } // expunged meanwhile
            let structure = Self.part(remote)
            guard let sections = PartialPlan.sections(of: structure, threshold: threshold) else {
                whole.append(summary)
                continue
            }
            let fetched = try await session.fetchSections(sections, of: summary.id)
            // A server that does not return every section (no MIME headers, say) cannot give a
            // faithful copy: fetch it whole instead.
            guard let header = fetched["HEADER"], sections.allSatisfy({ fetched[$0] != nil }),
                  PartialPlan.isConsistent(structure, sections: fetched) else {
                log.info("sync", "\(folder): the server left out sections of a large message; fetching it whole")
                whole.append(summary)
                continue
            }
            var parts = fetched
            parts["HEADER"] = nil
            let id = summary.id
            partials.append((summary, SyncedPartialMessage(
                header: header, structure: structure, sections: parts, size: summary.size ?? 0,
                remote: RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid),
                receivedAt: summary.internalDate ?? Date(), flags: Self.flags(summary.flags))))
        }
        if !partials.isEmpty {
            let outcomes = try await store.storeSyncedPartials(partials.map(\.message), account: account)
            for (entry, outcome) in zip(partials, outcomes) {
                guard outcome != nil else { whole.append(entry.summary); continue } // compare with a stored original
                result.stored += 1
                progress.imported += 1
                progress.remaining = max(0, progress.remaining - 1)
            }
            log.debug("sync", "\(folder): \(partials.count) large messages stored without their large attachments")
        }
        guard !whole.isEmpty else { return }
        let (batches, tooLarge) = SyncPlanner.batches(whole, maxMessages: options.bodyBatchMessages, maxBytes: options.bodyBatchBytes,
                                                     maxMessageSize: session.maximumMessageSize)
        reportTooLarge(tooLarge, folder: folder, into: &result)
        for batch in batches {
            let fetched = try await session.fetchMessages(batch.map(\.id))
            let outcomes = try await store.storeSynced(fetched.map(Self.synced), account: account)
            result.stored += outcomes.count
            progress.imported += outcomes.count
            progress.remaining = max(0, progress.remaining - outcomes.count)
        }
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
    private static func synced(_ message: FetchedMessage) -> SyncedMessage {
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
