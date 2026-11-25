import Foundation
import MailCore
import MailProvider
import MailStore

/// What an account's action replay is doing, for the window.
public struct ReplayProgress: Sendable, Equatable {
    public enum Activity: Sendable, Equatable {
        case idle
        case sending
        /// The provider could not be reached; the next try is at `retryAt` (or sooner, when the
        /// sync reconnects).
        case offline(reason: String, retryAt: Date)
        /// The provider refused the password; nothing is sent until the person signs in again.
        case signInFailed(reason: String)
    }

    public var activity: Activity = .idle
    public var status = MailActionStatus()

    public init() {}
}

/// What one replay did, for tests and the log.
public struct ReplayReport: Sendable, Equatable {
    /// Rows the provider now has.
    public var sent = 0
    /// Rows that needed nothing sent: they cancelled each other out, or the provider already
    /// had that state.
    public var settled = 0
    /// Rows not sent because the provider's state had moved on (MAIL-035).
    public var superseded = 0
    /// Rows the provider refused this time.
    public var refused = 0
    /// Rows left for later (waiting for the sync to map a message).
    public var waiting = 0
    /// Commands that changed something at the provider (STORE, MOVE, COPY, EXPUNGE, APPEND):
    /// a batch of hundreds goes as a few commands of up to ``ActionReplayer/batchSize`` UIDs
    /// each, never one per message (GKM-071).
    public var commands = 0

    public init() {}
}

/// Sends an account's action journal to the provider (GKM-015, MAIL-034).
///
/// - **Durable and local first.** Actions are rows in the store's journal before anything is
///   sent; the window shows them at once. The replay reads the journal, never memory.
/// - **Once.** One replay runs at a time per account (an actor with a single-flight guard). A
///   row is marked only after the provider confirmed it, and every operation is safe to repeat
///   after a crash between the two: flags are `+FLAGS`/`-FLAGS`; a move or delete of a UID that
///   is gone does nothing, and the row then finds the message gone and settles; a restore
///   searches the target folder for the exact bytes before it appends.
/// - **The provider wins a conflict.** A flag is sent only when the provider still has the value
///   the person saw when acting; a move only when the message is still where it was. Otherwise
///   the row is superseded and the provider's state shows (MAIL-035). Nothing is ever re-added
///   to a folder from local state except by an explicit Undo of a permanent delete.
/// - **Cheap.** Rows that cancel out (Undo before reconnecting, read then unread) send nothing;
///   flag rows go as one STORE per folder and value, moves as one MOVE per folder pair.
public actor ActionReplayer {
    /// The most UIDs one command carries. Consecutive UIDs go as ranges (`1:300`), so a command
    /// stays short; a cap still keeps each well inside what providers accept in one line.
    public static let batchSize = 500

    public nonisolated let account: MailAccountID
    public nonisolated let updates: AsyncStream<ReplayProgress>

    private let connector: any MailboxConnector
    private let store: MailStore
    private let log: MailLog
    private let reconnect: ReconnectPolicy
    private let continuation: AsyncStream<ReplayProgress>.Continuation
    private var loop: Task<Void, Never>?
    /// A kick that arrived while the loop was busy: the next wait returns at once.
    private var kicked = false
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var waiterCounter = 0
    private var isReplaying = false

    public private(set) var progress = ReplayProgress() {
        didSet { if progress != oldValue { continuation.yield(progress) } }
    }

    public init(account: MailAccountID, connector: any MailboxConnector, store: MailStore,
                reconnect: ReconnectPolicy = ReconnectPolicy(), log: MailLog = .disabled) {
        self.account = account
        self.connector = connector
        self.store = store
        self.reconnect = reconnect
        self.log = log
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    // MARK: - Control

    /// Sends whatever is queued now and whenever ``kick()`` says there is more, retrying with
    /// backoff while the provider is unreachable, until ``stop()``.
    public func start() {
        guard loop == nil else { return }
        kicked = true
        loop = Task { await self.run() }
    }

    public func stop() async {
        guard let loop else { return }
        self.loop = nil
        loop.cancel()
        wake(nil)
        await loop.value
    }

    /// There is something new to send (an action was taken), or the provider is reachable
    /// again (the sync reconnected): try now instead of at the next backoff.
    public func kick() {
        if waiter != nil { wake(nil) } else { kicked = true }
    }

    /// Waits for a kick, or `timeout`. Returns at once when a kick came in meanwhile.
    private func waitForKick(timeout: Duration?) async {
        if kicked || Task.isCancelled { kicked = false; return }
        waiterCounter += 1
        let id = waiterCounter
        await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.wake(id)
                }
            }
        }
    }

    /// Ends the current wait (only the wait `id`, when given: a late timer never ends a newer one).
    private func wake(_ id: Int?) {
        guard let waiter, id == nil || waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume()
    }

    /// Refreshes the status the window shows (after an action was taken locally).
    public func refreshStatus() async {
        if let status = try? await store.actionStatus(account: account) { progress.status = status }
    }

    /// One replay in a fresh session: everything queued, until nothing more can be sent. For
    /// tests and command-line use; the app uses ``start()``. Throws on a connection problem,
    /// leaving every unsent row queued.
    @discardableResult
    public func replayOnce() async throws -> ReplayReport {
        try await connector.withSession { session in try await self.replay(session) }
    }

    // MARK: - The loop

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            await refreshStatus()
            if progress.status.pending == 0 || isWaitingForSignIn {
                // Nothing to send (or no password): wait for the next action or reconnect.
                await waitForKick(timeout: nil)
                if case .signInFailed = progress.activity { progress.activity = .idle }
                continue
            }
            kicked = false
            progress.activity = .sending
            do {
                let report = try await replayOnce()
                failures = 0
                progress.activity = .idle
                if report.sent + report.settled + report.superseded == 0 {
                    // Only rows waiting for the sync (or refused ones backing off): try again after
                    // the next sync pass kicks, or in a minute.
                    await waitForKick(timeout: .seconds(60))
                }
            } catch {
                if Task.isCancelled { break }
                if case MailProviderError.authenticationFailed(let reason) = error {
                    progress.activity = .signInFailed(reason: reason)
                    continue
                }
                failures += 1
                let delay = reconnect.delay(beforeRetry: failures, random: Double.random(in: 0..<1))
                let reason = (error as? MailProviderError)?.description ?? String(describing: error)
                log.warning("actions", "\(account): \(reason); retrying in \(delay)")
                progress.activity = .offline(reason: reason, retryAt: Date().addingTimeInterval(Self.seconds(delay)))
                // Back off, but a kick (a reconnect seen by the sync, a new action) ends the wait.
                await waitForKick(timeout: delay)
            }
        }
        await refreshStatus()
    }

    private var isWaitingForSignIn: Bool {
        if case .signInFailed = progress.activity { return true }
        return false
    }

    // MARK: - A replay

    private func replay(_ session: any MailboxSession) async throws -> ReplayReport {
        guard !isReplaying else { return ReplayReport() }
        isReplaying = true
        defer { isReplaying = false }
        var report = ReplayReport()
        try await store.pruneActionJournal(account: account)
        // Each round sends what can go now; a message with several unchained moves needs more.
        for _ in 0..<5 {
            let rows = try await store.pendingActions(account: account)
            if rows.isEmpty { break }
            let before = report
            let folders = try await store.syncedFolders(account: account)
            var context = ReplayContext(folders: folders)
            try await replayFlags(rows.filter { !$0.kind.changesLocation }, session, &report)
            try await replayLocations(rows.filter { $0.kind.changesLocation }, session, &context, &report)
            if report == before || report.waiting > before.waiting || report.refused > before.refused { break }
        }
        progress.status = try await store.actionStatus(account: account)
        log.info("actions", "\(account): sent \(report.sent) in \(report.commands) commands, settled \(report.settled), superseded \(report.superseded), refused \(report.refused), waiting \(report.waiting)")
        return report
    }

    private struct ReplayContext {
        var folders: [SyncedFolder]
        /// Folder names at the provider, listed once per replay when a target may need creating.
        var listed: Set<String>?

        func role(of folder: String) -> String? { folders.first { $0.name == folder }?.role }
    }

    // MARK: Flags

    private struct FlagIntent {
        var message: MailMessageID
        var kind: MailActionKind
        var value: Bool
        var base: Bool?
        var rows: [MailActionRecord]
    }

    private func replayFlags(_ rows: [MailActionRecord], _ session: any MailboxSession, _ report: inout ReplayReport) async throws {
        // The net intent per message and flag: the last value asked for, against the provider
        // value the first row saw.
        var intents: [FlagIntent] = []
        var keys: [String: Int] = [:]
        for row in rows {
            guard let value = row.value else { continue }
            let key = row.message.rawValue + "|" + row.kind.rawValue
            if let index = keys[key] {
                intents[index].value = value
                intents[index].rows.append(row)
            } else {
                keys[key] = intents.count
                intents.append(FlagIntent(message: row.message, kind: row.kind, value: value, base: row.base, rows: [row]))
            }
        }

        // Where each message is at the provider now.
        var byFolder: [FolderKey: [(intent: FlagIntent, id: RemoteMessageID)]] = [:]
        var located: [Int: Int] = [:]
        for (index, intent) in intents.enumerated() {
            if let base = intent.base, base == intent.value {
                // Read, then unread again: nothing to tell the provider.
                try await store.settleActions(intent.rows, account: account)
                report.settled += intent.rows.count
                continue
            }
            let locations = try await store.remoteLocations(of: intent.message, account: account)
            if locations.isEmpty {
                if try await isAwaitingLocation(intent.message) {
                    report.waiting += intent.rows.count
                } else {
                    try await store.supersedeActions(intent.rows, reason: "no longer at the provider", account: account)
                    report.superseded += intent.rows.count
                }
                continue
            }
            located[index] = locations.count
            for location in locations {
                let id = RemoteMessageID(folder: location.mailbox, uidValidity: location.uidValidity, uid: location.uid)
                byFolder[FolderKey(folder: location.mailbox, uidValidity: location.uidValidity), default: []].append((intent, id))
            }
        }

        // Per folder: read the current flags, drop what the provider changed since, STORE the rest.
        var outcome: [String: FlagOutcome] = [:]   // per intent key
        for (folder, entries) in byFolder.sorted(by: { $0.key.folder < $1.key.folder }) {
            for chunk in SyncPlanner.chunks(entries, of: Self.batchSize) {
                let current: [RemoteMessageID: MailProvider.MessageFlags]
                do {
                    current = try await session.flags(of: chunk.map(\.id))
                } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
                    for entry in chunk { outcome[Self.key(entry.intent), default: .init()].problem = error }
                    continue
                }
                var stores: [String: (kind: MailActionKind, value: Bool, ids: [RemoteMessageID], keys: [String])] = [:]
                for entry in chunk {
                    let key = Self.key(entry.intent)
                    guard let flags = current[entry.id] else {
                        // Gone from this folder since the last sync; other locations may still have it.
                        outcome[key, default: .init()].gone += 1
                        continue
                    }
                    let value = entry.intent.kind == .seen ? flags.seen : flags.flagged
                    if value == entry.intent.value {
                        outcome[key, default: .init()].already += 1
                    } else if let base = entry.intent.base, value != base {
                        outcome[key, default: .init()].changedElsewhere = true
                    } else {
                        let storeKey = "\(entry.intent.kind.rawValue)|\(entry.intent.value)"
                        stores[storeKey, default: (entry.intent.kind, entry.intent.value, [], [])].ids.append(entry.id)
                        stores[storeKey]!.keys.append(key)
                    }
                }
                for (_, group) in stores.sorted(by: { $0.key < $1.key }) {
                    let flags = group.kind == .seen ? MailProvider.MessageFlags(seen: true) : MailProvider.MessageFlags(flagged: true)
                    do {
                        try await session.setFlags(flags, group.value ? .add : .remove, on: group.ids)
                        report.commands += 1
                        for key in group.keys { outcome[key, default: .init()].stored += 1 }
                    } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
                        for key in group.keys { outcome[key, default: .init()].problem = error }
                    }
                }
                _ = folder
            }
        }

        for (index, intent) in intents.enumerated() {
            guard let count = located[index] else { continue }
            let result = outcome[Self.key(intent)] ?? .init()
            if let problem = result.problem {
                if case .messageNotFound = problem {
                    // UIDVALIDITY changed: the sync re-maps the message; try again after it.
                    report.waiting += intent.rows.count
                } else {
                    try await store.recordFailedAttempt(intent.rows, error: problem.description, account: account)
                    report.refused += intent.rows.count
                }
            } else if result.changedElsewhere && result.stored == 0 {
                try await store.supersedeActions(intent.rows, reason: "changed at the provider before this change was sent",
                                                 account: account)
                report.superseded += intent.rows.count
            } else if result.gone == count {
                try await store.supersedeActions(intent.rows, reason: "no longer at the provider", account: account)
                report.superseded += intent.rows.count
            } else {
                try await store.completeFlagActions(intent.rows, account: account)
                if result.stored > 0 { report.sent += intent.rows.count } else { report.settled += intent.rows.count }
            }
        }
    }

    private struct FlagOutcome {
        var stored = 0
        var already = 0
        var gone = 0
        var changedElsewhere = false
        var problem: MailProviderError?
    }

    private struct FolderKey: Hashable {
        var folder: String
        var uidValidity: UInt32
    }

    private static func key(_ intent: FlagIntent) -> String { intent.message.rawValue + "|" + intent.kind.rawValue }

    // MARK: Locations

    /// The net effect of a message's open location rows.
    private struct LocationIntent {
        var message: MailMessageID
        /// Where the message is at the provider before; nil when it is not there (a restore).
        var from: String?
        /// Where it should end up; nil for gone (a permanent delete).
        var to: String?
        var createsTarget: Bool
        var rows: [MailActionRecord]
    }

    private func replayLocations(_ rows: [MailActionRecord], _ session: any MailboxSession,
                                 _ context: inout ReplayContext, _ report: inout ReplayReport) async throws {
        var intents: [LocationIntent] = []
        for (message, messageRows) in Dictionary(grouping: rows, by: \.message).sorted(by: { $0.key < $1.key }) {
            let ordered = messageRows.sorted { $0.sequence < $1.sequence }
            if let intent = Self.collapse(ordered) {
                if intent.from == intent.to {
                    // Moved and moved back (Undo before it was sent): nothing to send.
                    try await store.settleActions(intent.rows, account: account)
                    report.settled += intent.rows.count
                } else {
                    intents.append(intent)
                }
            } else if let first = ordered.first {
                // Not a chain (rows on different copies of the message): one at a time.
                intents.append(Self.collapse([first])!)
            }
            _ = message
        }

        // Moves from one folder to another go as one command per pair.
        var moves: [MovePair: [(intent: LocationIntent, id: RemoteMessageID)]] = [:]
        for intent in intents {
            switch (intent.from, intent.to) {
            case (let from?, let to?):
                guard let id = try await locate(intent, in: from, session, &report) else { continue }
                if intent.createsTarget, !(try await ensureFolder(to, session, &context)) {
                    try await store.recordFailedAttempt(intent.rows, error: "the folder \(to) could not be created", account: account)
                    report.refused += intent.rows.count
                    continue
                }
                moves[MovePair(from: from, uidValidity: id.uidValidity, to: to), default: []].append((intent, id))
            case (let from?, nil):
                guard let id = try await locate(intent, in: from, session, &report) else { continue }
                try await expunge(intent, id, session, &context, &report)
            case (nil, let to?):
                try await restore(intent, into: to, session, &report)
            case (nil, nil):
                try await store.settleActions(intent.rows, account: account)
                report.settled += intent.rows.count
            }
        }

        for (pair, entries) in moves.sorted(by: { ($0.key.from, $0.key.to) < ($1.key.from, $1.key.to) }) {
            // Never expunge from a folder that holds every message (Gmail's All Mail): there an
            // expunge can delete the message for good. Out of it, a move is a copy (MAIL-036).
            let copyOnly = context.role(of: pair.from) == FolderRole.all.rawValue
            for chunk in SyncPlanner.chunks(entries, of: Self.batchSize) {
                let ids = chunk.map(\.id)
                let mapping: [RemoteMessageID: RemoteMessageID]
                do {
                    mapping = copyOnly ? try await session.copy(ids, to: pair.to) : try await session.move(ids, to: pair.to)
                    report.commands += 1
                } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
                    for entry in chunk { try await refuse(entry.intent, error, &report) }
                    continue
                }
                for entry in chunk {
                    let old = RemoteLocation(mailbox: entry.id.folder, uidValidity: entry.id.uidValidity, uid: entry.id.uid)
                    let new = mapping[entry.id].map { RemoteLocation(mailbox: $0.folder, uidValidity: $0.uidValidity, uid: $0.uid) }
                    try await store.completeLocationActions(entry.intent.rows, from: copyOnly ? [] : [old], to: new.map { [$0] } ?? [],
                                                            awaitingLocation: true, account: account)
                    report.sent += entry.intent.rows.count
                }
            }
        }
    }

    private struct MovePair: Hashable {
        var from: String
        var uidValidity: UInt32
        var to: String
    }

    /// Folds a message's rows into one net change when each starts where the previous ended.
    private static func collapse(_ rows: [MailActionRecord]) -> LocationIntent? {
        guard let first = rows.first else { return nil }
        var position: String? = first.kind == .restore ? nil : first.source
        let start = position
        for row in rows {
            switch row.kind {
            case .move:
                guard row.source == position else { return nil }
                position = row.target
            case .expunge:
                guard row.source == position else { return nil }
                position = nil
            case .restore:
                guard position == nil else { return nil }
                position = row.target
            case .seen, .flagged:
                continue
            }
        }
        let createsTarget = rows.last { $0.target == position && $0.target != nil }?.createsTarget ?? false
        return LocationIntent(message: first.message, from: start, to: position, createsTarget: createsTarget, rows: rows)
    }

    /// The message's location in `folder`: from the mapping, or — right after a move the
    /// provider did not report ids for — by its exact bytes. Nil when it is not there: then the
    /// rows are superseded (or wait, while the sync has yet to map an earlier move).
    private func locate(_ intent: LocationIntent, in folder: String, _ session: any MailboxSession,
                        _ report: inout ReplayReport) async throws -> RemoteMessageID? {
        let locations = try await store.remoteLocations(of: intent.message, account: account)
        if let location = locations.first(where: { $0.mailbox == folder }) {
            return RemoteMessageID(folder: location.mailbox, uidValidity: location.uidValidity, uid: location.uid)
        }
        if let found = try await findByContent(intent.message, in: folder, session) {
            try await store.record(RemoteLocation(mailbox: found.folder, uidValidity: found.uidValidity, uid: found.uid),
                                   for: intent.message, account: account)
            return found
        }
        if try await isAwaitingLocation(intent.message) {
            report.waiting += intent.rows.count
        } else {
            try await store.supersedeActions(intent.rows, reason: "no longer in \(folder) at the provider", account: account)
            report.superseded += intent.rows.count
        }
        return nil
    }

    private func expunge(_ intent: LocationIntent, _ id: RemoteMessageID, _ session: any MailboxSession,
                         _ context: inout ReplayContext, _ report: inout ReplayReport) async throws {
        guard context.role(of: id.folder) != FolderRole.all.rawValue else {
            // Deleting from All Mail deletes the message from every folder; the app never asks for it.
            try await store.supersedeActions(intent.rows, reason: "messages are never deleted from All Mail", account: account)
            report.superseded += intent.rows.count
            return
        }
        do {
            try await session.expunge([id])
            report.commands += 1
        } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
            try await refuse(intent, error, &report)
            return
        }
        try await store.completeLocationActions(
            intent.rows, from: [RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid)], to: [],
            awaitingLocation: false, account: account)
        report.sent += intent.rows.count
    }

    /// Puts the stored original back (Undo of a permanent delete). Looks for the exact bytes
    /// first, so a restore repeated after a crash never makes a second copy.
    private func restore(_ intent: LocationIntent, into folder: String, _ session: any MailboxSession,
                         _ report: inout ReplayReport) async throws {
        do {
            if let existing = try await findByContent(intent.message, in: folder, session) {
                try await store.completeLocationActions(
                    intent.rows, from: [], to: [RemoteLocation(mailbox: existing.folder, uidValidity: existing.uidValidity, uid: existing.uid)],
                    awaitingLocation: false, account: account)
                report.settled += intent.rows.count
                return
            }
            let original = try await store.originalData(of: intent.message)
            let flags = try await store.flags(of: intent.message)
            let id = try await session.append(original, to: folder, flags: MailProvider.MessageFlags(seen: flags.seen, flagged: flags.flagged))
            report.commands += 1
            try await store.completeLocationActions(
                intent.rows, from: [], to: id.map { [RemoteLocation(mailbox: $0.folder, uidValidity: $0.uidValidity, uid: $0.uid)] } ?? [],
                awaitingLocation: true, account: account)
            report.sent += intent.rows.count
        } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
            try await refuse(intent, error, &report)
        }
    }

    /// The message in `folder` with exactly the stored bytes, found by its Message-ID. A
    /// Message-ID alone never identifies a message (MAIL-026): the bytes must match.
    private func findByContent(_ message: MailMessageID, in folder: String, _ session: any MailboxSession) async throws -> RemoteMessageID? {
        guard let messageID = try? await store.message(message).front.messageId, !messageID.isEmpty,
              let original = try? await store.originalData(of: message) else { return nil }
        let candidates: [RemoteMessageID]
        do {
            candidates = try await session.search(messageIDHeader: messageID, in: folder)
        } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
            return nil
        }
        for candidate in candidates {
            if let fetched = try? await session.fetchMessage(candidate), fetched.rawMessage == original { return candidate }
        }
        return nil
    }

    private func ensureFolder(_ folder: String, _ session: any MailboxSession, _ context: inout ReplayContext) async throws -> Bool {
        if context.listed == nil { context.listed = Set(try await session.listFolders().map(\.id)) }
        if context.listed!.contains(folder) { return true }
        do {
            try await session.createFolder(folder)
            log.info("actions", "\(account): created \(folder)")
            context.listed!.insert(folder)
            return true
        } catch let error as MailProviderError where !error.isConnectionProblem && error.authenticationFailedReason == nil {
            log.warning("actions", "\(account): could not create \(folder): \(error)")
            return false
        }
    }

    private func refuse(_ intent: LocationIntent, _ error: MailProviderError, _ report: inout ReplayReport) async throws {
        if case .messageNotFound = error {
            report.waiting += intent.rows.count
            return
        }
        try await store.recordFailedAttempt(intent.rows, error: error.description, account: account)
        report.refused += intent.rows.count
    }

    /// True while a move or restore of the message reached the provider but the sync has not
    /// found where it went: rows that need its location wait.
    private func isAwaitingLocation(_ message: MailMessageID) async throws -> Bool {
        try await store.awaitingActions(account: account).contains { $0.message == message }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
