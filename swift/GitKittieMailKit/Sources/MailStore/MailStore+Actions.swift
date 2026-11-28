import Foundation
import MailCore

// Everyday actions (GKM-015): read/unread, flag, move, archive, trash, delete from Trash, and
// Undo — applied here at once, queued in the account's action journal, and replayed against the
// provider by MailSync's `ActionReplayer`. Decisions MAIL-034..037 (docs/decisions/MAIL-034.md..MAIL-037.md).
//
// What the window shows for a message is the provider's state as last synced (the mapping and
// the `flags` table) with the journal's open rows laid over it, in order. The overlay is applied
// wherever the store writes the index, so neither a sync pass nor an index rebuild undoes a
// change that has not reached the provider yet. Nothing here ever deletes a message's files:
// a message removed at the provider stays in the mail folder (MAIL-029).

/// One thing the person asked for.
public enum MailAction: Sendable, Hashable {
    case setSeen(Bool)
    case setFlagged(Bool)
    /// From one provider folder to another. `createTarget` creates the target at the provider
    /// first when it does not exist (an account without an Archive folder, MAIL-036).
    case move(from: String, to: String, createTarget: Bool = false)
    /// Removes the message from a folder at the provider for good. The app only offers it in
    /// Trash, after a confirmation; the local copy stays (MAIL-029), so Undo can put it back.
    case deletePermanently(from: String)
}

/// An action on one message.
public struct MailChange: Sendable, Hashable {
    public var message: MailMessageID
    public var action: MailAction

    public init(_ message: MailMessageID, _ action: MailAction) {
        self.message = message
        self.action = action
    }
}

/// What one person-level action became: the unit Undo reverses.
public struct MailActionBatch: Sendable, Hashable {
    public var id: String
    /// The accounts whose journals hold its rows.
    public var accounts: [MailAccountID]
    /// How many messages it changed.
    public var count: Int
}

/// The journal of one account, as the window shows it.
public struct MailActionStatus: Sendable, Equatable {
    /// Changes made here that the provider does not have yet.
    public var pending = 0
    /// Changes the provider refused repeatedly; they wait for Try Again or Discard.
    public var failed = 0
    public var lastFailure: String?
    /// Changes not sent in the last hour because the provider's state had moved on.
    public var recentlySuperseded = 0
    /// Messages with changes still on their way.
    public var pendingMessages: Set<MailMessageID> = []

    public init() {}
}

extension MailStore {
    /// How long settled rows stay, so a recent action can still be undone after it reached the
    /// provider.
    static let journalRetention: TimeInterval = 7 * 24 * 3600
    /// Refusals (not network failures) before a row is `failed`.
    public static let actionAttemptLimit = 5

    // MARK: - Acting

    /// Applies the changes here at once and queues them for the provider. Changes that do not
    /// apply (a move from a folder the message is not in, a flag already set) are skipped.
    /// Messages that live only on this Mac (imported `.eml`) change locally and are not queued.
    /// Returns nil when nothing changed.
    @discardableResult
    public func perform(_ changes: [MailChange], now: Date = Date()) throws -> MailActionBatch? {
        let batch = UUID().uuidString
        var count = 0
        var accounts: [MailAccountID] = []
        for (account, group) in try groupByAccount(changes) {
            let made = try perform(group, account: account, batch: batch, now: now)
            if made > 0 { count += made; accounts.append(account) }
        }
        return count == 0 ? nil : MailActionBatch(id: batch, accounts: accounts, count: count)
    }

    /// Reverses a batch: open rows are cancelled by their inverse (the replay sends neither),
    /// rows the provider has are reversed at the provider — a move goes back, a permanent delete
    /// puts the stored original back. Returns the batch that undoes it (Redo undoes that).
    @discardableResult
    public func undo(_ batch: MailActionBatch, now: Date = Date()) throws -> MailActionBatch? {
        let inverse = UUID().uuidString
        var count = 0
        var accounts: [MailAccountID] = []
        for account in batch.accounts {
            let name = try SafePath.component(account.rawValue)
            let mapping = try mapping(for: name)
            var rows: [RemoteMapping.NewAction] = []
            var touched: [MailMessageID] = []
            for record in try mapping.actions(ofBatch: batch.id).reversed() {
                // A row that never took effect (superseded, failed) has nothing to undo.
                guard record.state == .pending || record.state == .awaitingSync || record.state == .done else { continue }
                let current = try effectiveState(of: record.message, mapping: mapping)
                let server = try mapping.serverFlags(of: record.message)
                switch record.kind {
                case .seen:
                    let back = record.previous ?? !(record.value ?? false)
                    rows.append(.init(message: record.message, kind: .seen, value: back, base: server?.seen, previous: current.flags.seen))
                case .flagged:
                    let back = record.previous ?? !(record.value ?? false)
                    rows.append(.init(message: record.message, kind: .flagged, value: back, base: server?.flagged, previous: current.flags.flagged))
                case .move:
                    guard let source = record.source, let target = record.target else { continue }
                    rows.append(.init(message: record.message, kind: .move, source: target, target: source))
                case .expunge:
                    guard let source = record.source else { continue }
                    rows.append(.init(message: record.message, kind: .restore, target: source))
                case .restore:
                    guard let target = record.target else { continue }
                    rows.append(.init(message: record.message, kind: .expunge, source: target))
                }
                touched.append(record.message)
            }
            guard !rows.isEmpty else { continue }
            try mapping.database.transaction { try mapping.insert(rows, batch: inverse, at: now) }
            try refreshIndex(Set(touched), account: account, mapping: mapping)
            count += Set(touched).count
            accounts.append(account)
        }
        return count == 0 ? nil : MailActionBatch(id: inverse, accounts: accounts, count: count)
    }

    /// The folders the window shows the message in: the provider's, with open changes applied.
    public func effectiveMailboxes(of id: MailMessageID) throws -> Set<String> {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        return try effectiveState(of: id, mapping: mapping(for: SafePath.component(account.rawValue))).mailboxes
    }

    /// The account's journal, for the sidebar and the list.
    public func actionStatus(account: MailAccountID, now: Date = Date()) throws -> MailActionStatus {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        var status = MailActionStatus()
        let open = try mapping.actions(in: [.pending])
        status.pending = open.count
        status.pendingMessages = Set(open.map(\.message))
        status.failed = try mapping.count(in: .failed)
        status.lastFailure = try mapping.lastError(in: .failed)
        status.recentlySuperseded = try mapping.countSuperseded(since: now.addingTimeInterval(-3600))
        return status
    }

    /// Failed changes go back in the queue.
    public func retryFailedActions(account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let ids = try mapping.retryFailed()
        try refreshIndex(Set(ids), account: account, mapping: mapping)
    }

    /// Failed changes are dropped; the provider's state stands and the window shows it.
    public func discardFailedActions(account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let ids = try mapping.discardFailed()
        try refreshIndex(Set(ids), account: account, mapping: mapping)
    }

    // MARK: - The replay's side (MailSync ActionReplayer)

    /// Rows still to send, oldest first.
    public func pendingActions(account: MailAccountID) throws -> [MailActionRecord] {
        try mapping(for: SafePath.component(account.rawValue)).actions(in: [.pending])
    }

    /// Rows the provider did but has not reported a location for yet.
    public func awaitingActions(account: MailAccountID) throws -> [MailActionRecord] {
        try mapping(for: SafePath.component(account.rawValue)).actions(in: [.awaitingSync])
    }

    /// The provider set these flags: the rows are done and the provider's flags are recorded.
    public func completeFlagActions(_ records: [MailActionRecord], account: MailAccountID, now: Date = Date()) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try mapping.database.transaction {
            for record in records {
                guard let value = record.value else { continue }
                try mapping.setServerFlag(record.kind, value, for: record.message)
            }
            try mapping.setState(.done, of: records.map(\.sequence), at: now)
        }
        try refreshIndex(Set(records.map(\.message)), account: account, mapping: mapping)
    }

    /// The provider did a move, expunge or restore. `from` is the location it left (forgotten
    /// here); `to` is where it is now when the provider said (UIDPLUS). With `awaitingLocation`
    /// (it went somewhere, but the provider did not say where), the rows keep the message shown
    /// in its new folder until the sync finds it there (``settleAwaitingActions``).
    public func completeLocationActions(_ records: [MailActionRecord], from: [RemoteLocation], to: [RemoteLocation],
                                        awaitingLocation: Bool, account: MailAccountID, now: Date = Date()) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let ids = Set(records.map(\.message))
        guard let id = ids.first, ids.count == 1 else {
            precondition(ids.count <= 1, "one message per location completion")
            return
        }
        try mapping.database.transaction {
            for location in from { try mapping.forget(location) }
            for location in to {
                try mapping.record(location, for: id)
                try index.setDeletedAtProvider(nil, for: id)
            }
            let sequences = records.map(\.sequence).sorted()
            if awaitingLocation, to.isEmpty, let last = sequences.last {
                // Only the last row says where the message ended up.
                try mapping.setState(.done, of: Array(sequences.dropLast()), at: now)
                try mapping.setState(.awaitingSync, of: [last], at: now)
            } else {
                // When the provider said where the message went, it was this command that moved
                // it: a sync that saw it leave the source meanwhile and superseded the row was
                // seeing this very move. The row is done, so Undo can bring the message back
                // (GKM-071: with hundreds in one batch, the sync often looks in between).
                try mapping.setState(.done, of: sequences, at: now, includingSuperseded: !to.isEmpty)
            }
        }
        try refreshIndex(ids, account: account, mapping: mapping)
    }

    /// Rows not sent because the provider's state moved on, or the message is no longer where
    /// they expected it. The window falls back to the provider's state.
    public func supersedeActions(_ records: [MailActionRecord], reason: String, account: MailAccountID, now: Date = Date()) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try mapping.setState(.superseded, of: records.map(\.sequence), error: reason, at: now)
        try refreshIndex(Set(records.map(\.message)), account: account, mapping: mapping)
    }

    /// Rows the replay found already done, or that cancel each other out: nothing was sent.
    public func settleActions(_ records: [MailActionRecord], account: MailAccountID, now: Date = Date()) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try mapping.setState(.done, of: records.map(\.sequence), at: now)
        try refreshIndex(Set(records.map(\.message)), account: account, mapping: mapping)
    }

    /// The provider refused these rows (not a network failure). After
    /// ``actionAttemptLimit`` refusals they are `failed` and shown.
    public func recordFailedAttempt(_ records: [MailActionRecord], error: String, account: MailAccountID, now: Date = Date()) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try mapping.recordAttempt(of: records.map(\.sequence), error: error, limit: Self.actionAttemptLimit, at: now)
        try refreshIndex(Set(records.map(\.message)), account: account, mapping: mapping)
    }

    /// After the sync listed `mailbox` (at `listedAt`): rows waiting for a message to show up
    /// there are done — the sync has mapped it, or it is not there and the provider's state wins.
    public func settleAwaitingActions(mailbox: String, listedAt: Date, account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let waiting = try mapping.awaiting(target: mailbox, finishedBefore: listedAt)
        guard !waiting.isEmpty else { return }
        try mapping.setState(.done, of: waiting.map(\.sequence), at: listedAt)
        try refreshIndex(Set(waiting.map(\.message)), account: account, mapping: mapping)
    }

    /// Drops settled rows past the undo window.
    public func pruneActionJournal(account: MailAccountID, now: Date = Date()) throws {
        try mapping(for: SafePath.component(account.rawValue)).pruneSettled(before: now.addingTimeInterval(-Self.journalRetention))
    }

    /// The provider's flags as last synced (no open changes laid over them), or nil.
    public func providerFlags(of id: MailMessageID, account: MailAccountID) throws -> MessageFlags? {
        try mapping(for: SafePath.component(account.rawValue)).serverFlags(of: id)
    }

    // MARK: - CONDSTORE (RFC 7162)

    /// The HIGHESTMODSEQ up to which the folder's flags are applied here, at this UIDVALIDITY.
    public func highestModSeq(folder: String, uidValidity: UInt32, account: MailAccountID) throws -> UInt64? {
        try mapping(for: SafePath.component(account.rawValue)).highestModSeq(folder: folder, uidValidity: uidValidity)
    }

    /// Checkpoints the folder's HIGHESTMODSEQ. Call only after the flags it covers are stored.
    public func saveHighestModSeq(_ value: UInt64?, folder: String, uidValidity: UInt32, account: MailAccountID) throws {
        try mapping(for: SafePath.component(account.rawValue)).saveHighestModSeq(value, folder: folder, uidValidity: uidValidity)
    }

    // MARK: - The overlay

    struct EffectiveState {
        var mailboxes: Set<String>
        var flags: MessageFlags
    }

    /// The provider's state with the journal's open rows applied in order.
    func effectiveState(of id: MailMessageID, mapping: RemoteMapping) throws -> EffectiveState {
        var mailboxes = Set(try mapping.locations(of: id).map(\.mailbox))
        var flags = try mapping.serverFlags(of: id) ?? MessageFlags()
        for row in try mapping.overlay(of: id) {
            switch row.kind {
            case .seen: if let value = row.value { flags.seen = value }
            case .flagged: if let value = row.value { flags.flagged = value }
            case .move:
                if row.state == .pending, let source = row.source { mailboxes.remove(source) }
                if let target = row.target { mailboxes.insert(target) }
            case .expunge:
                if let source = row.source { mailboxes.remove(source) }
            case .restore:
                if let target = row.target { mailboxes.insert(target) }
            }
        }
        return EffectiveState(mailboxes: mailboxes, flags: flags)
    }

    /// Writes the effective folders and flags of these messages into the index.
    func refreshIndex(_ ids: Set<MailMessageID>, account: MailAccountID, mapping: RemoteMapping) throws {
        for id in ids.sorted() {
            let state = try effectiveState(of: id, mapping: mapping)
            try index.setMailboxes(state.mailboxes, for: id, account: account)
            try index.setFlags(state.flags, for: id)
        }
    }

    /// Lays the open rows over the index again for every message that has them (after a
    /// rebuild or a bulk membership change).
    func reapplyOverlay(account: MailAccountID, mapping: RemoteMapping, touching mailbox: String? = nil) throws {
        let ids = try mailbox.map { try mapping.overlaidMessages(touching: $0) } ?? mapping.overlaidMessages()
        try refreshIndex(Set(ids), account: account, mapping: mapping)
    }

    /// The sync recorded the provider's flags: an open flag row whose base no longer matches
    /// the provider was overtaken by a change made elsewhere, and the provider wins (MAIL-035).
    func reconcileFlagRows(with flags: [MailMessageID: MailMessageFlags], mapping: RemoteMapping, now: Date) throws {
        for (id, server) in flags {
            let open = try mapping.overlay(of: id).filter { $0.state == .pending && ($0.kind == .seen || $0.kind == .flagged) }
            guard !open.isEmpty else { continue }
            for kind in [MailActionKind.seen, .flagged] {
                let rows = open.filter { $0.kind == kind }
                guard let base = rows.first?.base else { continue }
                let value = kind == .seen ? server.seen : server.flagged
                if value != base {
                    try mapping.setState(.superseded, of: rows.map(\.sequence),
                                         error: "changed at the provider before this change was sent", at: now)
                }
            }
        }
    }

    /// The sync saw the message leave `mailbox`: open moves and deletes from there can no
    /// longer happen, and must not bring it back.
    func supersedeLocationRows(of id: MailMessageID, leaving mailbox: String, mapping: RemoteMapping, now: Date) throws {
        let rows = try mapping.overlay(of: id).filter { $0.state == .pending && $0.kind.changesLocation && $0.source == mailbox }
        guard !rows.isEmpty else { return }
        // Only when nothing else still puts it there (the stored location was the last one).
        guard try !mapping.locations(of: id).contains(where: { $0.mailbox == mailbox }) else { return }
        try mapping.setState(.superseded, of: rows.map(\.sequence), error: "no longer in \(mailbox) at the provider", at: now)
    }

    // MARK: - Helpers

    private func groupByAccount(_ changes: [MailChange]) throws -> [(MailAccountID, [MailChange])] {
        var order: [MailAccountID] = []
        var groups: [MailAccountID: [MailChange]] = [:]
        for change in changes {
            guard let account = try index.account(of: change.message) else { throw MailStoreError.messageNotFound(change.message.rawValue) }
            if groups[account] == nil { order.append(account) }
            groups[account, default: []].append(change)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private func perform(_ changes: [MailChange], account: MailAccountID, batch: String, now: Date) throws -> Int {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        var rows: [RemoteMapping.NewAction] = []
        var touched = Set<MailMessageID>()
        // What each message looks like as the rows pile up, so a batch that marks and moves the
        // same message sees its own earlier rows.
        var states: [MailMessageID: EffectiveState] = [:]
        for change in changes {
            let id = change.message
            var state = try states[id] ?? effectiveState(of: id, mapping: mapping)
            let remote = try !mapping.locations(of: id).isEmpty || !mapping.overlay(of: id).isEmpty
            let server = try mapping.serverFlags(of: id)
            switch change.action {
            case .setSeen(let value):
                guard state.flags.seen != value else { continue }
                if remote {
                    rows.append(.init(message: id, kind: .seen, value: value, base: server?.seen, previous: state.flags.seen))
                } else {
                    // Only on this Mac: no provider to tell.
                    var flags = server ?? MessageFlags()
                    flags.seen = value
                    try mapping.setFlags(flags, for: id)
                }
                state.flags.seen = value
            case .setFlagged(let value):
                guard state.flags.flagged != value else { continue }
                if remote {
                    rows.append(.init(message: id, kind: .flagged, value: value, base: server?.flagged, previous: state.flags.flagged))
                } else {
                    var flags = server ?? MessageFlags()
                    flags.flagged = value
                    try mapping.setFlags(flags, for: id)
                }
                state.flags.flagged = value
            case .move(let source, let target, let create):
                guard source != target, state.mailboxes.contains(source) else { continue }
                rows.append(.init(message: id, kind: .move, source: source, target: target, createsTarget: create))
                state.mailboxes.remove(source)
                state.mailboxes.insert(target)
            case .deletePermanently(let source):
                guard state.mailboxes.contains(source) else { continue }
                rows.append(.init(message: id, kind: .expunge, source: source))
                state.mailboxes.remove(source)
            }
            states[id] = state
            touched.insert(id)
        }
        if !rows.isEmpty {
            try mapping.database.transaction { try mapping.insert(rows, batch: batch, at: now) }
        }
        try refreshIndex(touched, account: account, mapping: mapping)
        return touched.count
    }
}
