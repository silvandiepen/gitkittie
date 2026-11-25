import Foundation
import MailCore

// The offline action journal (GKM-015, MAIL-034): every everyday action on a message that lives
// at a provider is a row in `sync.sqlite`, beside the mapping it changes, so applying it locally
// and queuing it for the provider is one transaction. Device state (MAIL-013): never in the mail
// folder, never synced — each device replays its own actions against the provider.

/// What one journal row asks the provider to do.
public enum MailActionKind: String, Sendable, Codable, CaseIterable {
    /// Set or clear \Seen.
    case seen
    /// Set or clear \Flagged.
    case flagged
    /// Move the message from `source` to `target`.
    case move
    /// Remove the message from `source` for good (only ever from Trash, after confirmation).
    case expunge
    /// Put the stored original back into `target` (the undo of `expunge`).
    case restore

    public var changesLocation: Bool { self == .move || self == .expunge || self == .restore }
}

/// Where a journal row is.
public enum MailActionState: String, Sendable, Codable {
    /// Applied here, not yet at the provider.
    case pending
    /// The provider did it, but did not say where the message now is (no UIDPLUS): the row
    /// keeps the local view right until the sync finds the message in its new folder.
    case awaitingSync
    /// The provider has it.
    case done
    /// Not sent: the provider changed the same thing after this device last saw it, or the
    /// message is no longer where the action expected it. The provider's state wins.
    case superseded
    /// The provider refused it repeatedly; shown to the person, who may try again or discard it.
    case failed
}

/// One row of the journal.
public struct MailActionRecord: Sendable, Hashable, Identifiable {
    public var id: Int64 { sequence }
    public var sequence: Int64
    /// The person's action this row belongs to: what one Undo reverses.
    public var batch: String
    public var message: MailMessageID
    public var kind: MailActionKind
    /// Seen / flagged: the value asked for.
    public var value: Bool?
    /// Seen / flagged: the provider's value when the person acted (`nil` when never synced). A
    /// provider value that differs from it at replay time means someone else changed it since,
    /// and the provider wins (MAIL-035).
    public var base: Bool?
    /// Seen / flagged: the value the person saw before acting, which Undo goes back to.
    public var previous: Bool?
    public var source: String?
    public var target: String?
    /// Create `target` at the provider when it does not exist (an Archive folder the account
    /// does not have yet, MAIL-036).
    public var createsTarget: Bool
    public var state: MailActionState
    public var attempts: Int
    public var lastError: String?
    public var created: Date
}

extension RemoteMapping {
    /// Schema 3 → 4 (GKM-015): the action journal and the CONDSTORE checkpoint per folder.
    func migrateToActionJournal() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS actions (
              seq INTEGER PRIMARY KEY AUTOINCREMENT,
              batch TEXT NOT NULL,
              local_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              value INTEGER, base INTEGER, previous INTEGER,
              source TEXT, target TEXT,
              creates_target INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL DEFAULT 'pending',
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              created REAL NOT NULL,
              finished REAL
            );
            CREATE INDEX IF NOT EXISTS actions_by_state ON actions (state, local_id);
            CREATE INDEX IF NOT EXISTS actions_by_message ON actions (local_id, seq);
            CREATE INDEX IF NOT EXISTS actions_by_batch ON actions (batch);
            """)
        if try !columnExists("highest_modseq", in: "folder_state") {
            try database.execute("ALTER TABLE folder_state ADD COLUMN highest_modseq INTEGER")
        }
    }

    func columnExists(_ column: String, in table: String) throws -> Bool {
        try database.prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ?").bind([.text(table), .text(column)]).step()
    }

    // MARK: Writing

    struct NewAction {
        var message: MailMessageID
        var kind: MailActionKind
        var value: Bool?
        var base: Bool?
        var previous: Bool?
        var source: String?
        var target: String?
        var createsTarget = false
    }

    func insert(_ actions: [NewAction], batch: String, at date: Date) throws {
        let statement = try database.prepare("""
            INSERT INTO actions (batch, local_id, kind, value, base, previous, source, target, creates_target, created)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for action in actions {
            try statement.run([
                .text(batch), .text(action.message.rawValue), .text(action.kind.rawValue),
                Self.bool(action.value), Self.bool(action.base), Self.bool(action.previous),
                .optional(action.source), .optional(action.target), .int(action.createsTarget ? 1 : 0),
                .double(date.timeIntervalSince1970),
            ])
        }
    }

    /// Moves rows to a new state. Only rows still `pending` or `awaitingSync` change: a row the
    /// sync already settled (superseded) stays as it is, unless `includingSuperseded` (the
    /// provider confirmed that this row's own command did it, GKM-071).
    func setState(_ state: MailActionState, of sequences: [Int64], error: String? = nil, at date: Date,
                  includingSuperseded: Bool = false) throws {
        guard !sequences.isEmpty else { return }
        let states = includingSuperseded ? "'pending', 'awaitingSync', 'failed', 'superseded'" : "'pending', 'awaitingSync', 'failed'"
        let statement = try database.prepare("""
            UPDATE actions SET state = ?, last_error = COALESCE(?, last_error), finished = ?
            WHERE seq = ? AND state IN (\(states))
            """)
        for sequence in sequences {
            try statement.run([.text(state.rawValue), .optional(error), .double(date.timeIntervalSince1970), .int(sequence)])
        }
    }

    /// Counts a failed attempt; after `limit` attempts the rows are `failed`.
    func recordAttempt(of sequences: [Int64], error: String, limit: Int, at date: Date) throws {
        let statement = try database.prepare("""
            UPDATE actions SET attempts = attempts + 1, last_error = ?,
              state = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE state END,
              finished = CASE WHEN attempts + 1 >= ? THEN ? ELSE finished END
            WHERE seq = ? AND state = 'pending'
            """)
        for sequence in sequences {
            try statement.run([.text(error), .int(Int64(limit)), .int(Int64(limit)), .double(date.timeIntervalSince1970), .int(sequence)])
        }
    }

    /// Failed rows back to pending, for "Try Again".
    func retryFailed() throws -> [MailMessageID] {
        let ids = try messages(where: "state = 'failed'")
        try database.execute("UPDATE actions SET state = 'pending', attempts = 0, finished = NULL WHERE state = 'failed'")
        return ids
    }

    /// Failed rows dropped, for "Discard": the provider's state stands.
    func discardFailed() throws -> [MailMessageID] {
        let ids = try messages(where: "state = 'failed'")
        try database.execute("UPDATE actions SET state = 'superseded' WHERE state = 'failed'")
        return ids
    }

    /// Settled rows older than `date` are only kept for Undo; past that they go.
    func pruneSettled(before date: Date) throws {
        try database.prepare("DELETE FROM actions WHERE state IN ('done', 'superseded') AND finished < ?")
            .run([.double(date.timeIntervalSince1970)])
    }

    // MARK: Reading

    /// Rows in these states, oldest first.
    func actions(in states: [MailActionState]) throws -> [MailActionRecord] {
        let list = states.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return try records(try database.prepare("SELECT \(Self.columns) FROM actions WHERE state IN (\(list)) ORDER BY seq"))
    }

    func actions(ofBatch batch: String) throws -> [MailActionRecord] {
        try records(try database.prepare("SELECT \(Self.columns) FROM actions WHERE batch = ? ORDER BY seq").bind([.text(batch)]))
    }

    /// The rows that still shape what this device shows for a message: pending flag and
    /// location changes, and location changes the provider made but the sync has not mapped.
    func overlay(of id: MailMessageID) throws -> [MailActionRecord] {
        try records(try database.prepare("""
            SELECT \(Self.columns) FROM actions
            WHERE local_id = ? AND (state = 'pending' OR (state = 'awaitingSync' AND kind IN ('move', 'restore')))
            ORDER BY seq
            """).bind([.text(id.rawValue)]))
    }

    /// Messages with rows that touch `mailbox` and still shape the local view.
    func overlaidMessages(touching mailbox: String) throws -> [MailMessageID] {
        try messages(where: "state IN ('pending', 'awaitingSync') AND (source = ? OR target = ?)", [.text(mailbox), .text(mailbox)])
    }

    /// Every message with a row that still shapes the local view.
    func overlaidMessages() throws -> [MailMessageID] {
        try messages(where: "state IN ('pending', 'awaitingSync')")
    }

    func count(in state: MailActionState) throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM actions WHERE state = ?").bind([.text(state.rawValue)])
        return try statement.step() ? statement.int(0) : 0
    }

    func lastError(in state: MailActionState) throws -> String? {
        let statement = try database.prepare("SELECT last_error FROM actions WHERE state = ? AND last_error IS NOT NULL ORDER BY seq DESC LIMIT 1")
            .bind([.text(state.rawValue)])
        return try statement.step() ? statement.text(0) : nil
    }

    func countSuperseded(since date: Date) throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM actions WHERE state = 'superseded' AND finished >= ?")
            .bind([.double(date.timeIntervalSince1970)])
        return try statement.step() ? statement.int(0) : 0
    }

    /// `awaitingSync` rows whose message should now be in `mailbox`, finished before `date`.
    func awaiting(target mailbox: String, finishedBefore date: Date) throws -> [MailActionRecord] {
        try records(try database.prepare("""
            SELECT \(Self.columns) FROM actions WHERE state = 'awaitingSync' AND target = ? AND finished < ? ORDER BY seq
            """).bind([.text(mailbox), .double(date.timeIntervalSince1970)]))
    }

    // MARK: Flags of one kind

    /// Writes one provider flag the replay just set.
    func setServerFlag(_ kind: MailActionKind, _ value: Bool, for id: MailMessageID) throws {
        let column = kind == .seen ? "seen" : "flagged"
        try database.prepare("""
            INSERT INTO flags (local_id, seen, flagged) VALUES (?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET \(column) = excluded.\(column)
            """).run([.text(id.rawValue), .int(kind == .seen && value ? 1 : 0), .int(kind == .flagged && value ? 1 : 0)])
    }

    /// The provider's flags as last synced, or nil when the message never had a row.
    func serverFlags(of id: MailMessageID) throws -> MessageFlags? {
        let statement = try database.prepare("SELECT seen, flagged FROM flags WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? MessageFlags(seen: statement.int(0) != 0, flagged: statement.int(1) != 0) : nil
    }

    // MARK: CONDSTORE

    func highestModSeq(folder: String, uidValidity: UInt32) throws -> UInt64? {
        let statement = try database.prepare("SELECT highest_modseq FROM folder_state WHERE name = ? AND uid_validity = ?")
            .bind([.text(folder), .int(Int64(uidValidity))])
        guard try statement.step(), !statement.isNull(0) else { return nil }
        return UInt64(statement.int(0))
    }

    func saveHighestModSeq(_ value: UInt64?, folder: String, uidValidity: UInt32) throws {
        try database.prepare("UPDATE folder_state SET highest_modseq = ? WHERE name = ? AND uid_validity = ?")
            .run([value.map { .int(Int64(bitPattern: $0)) } ?? .null, .text(folder), .int(Int64(uidValidity))])
    }

    // MARK: Helpers

    private static let columns = "seq, batch, local_id, kind, value, base, previous, source, target, creates_target, state, attempts, last_error, created"

    private func records(_ statement: SQLiteDatabase.Statement) throws -> [MailActionRecord] {
        var result: [MailActionRecord] = []
        func bool(_ column: Int32) -> Bool? { statement.isNull(column) ? nil : statement.int(column) != 0 }
        while try statement.step() {
            guard let id = statement.text(2).flatMap(MailMessageID.init),
                  let kind = statement.text(3).flatMap(MailActionKind.init(rawValue:)),
                  let state = statement.text(10).flatMap(MailActionState.init(rawValue:)) else { continue }
            result.append(MailActionRecord(
                sequence: Int64(statement.int(0)), batch: statement.text(1) ?? "", message: id, kind: kind,
                value: bool(4), base: bool(5), previous: bool(6), source: statement.text(7), target: statement.text(8),
                createsTarget: statement.int(9) != 0, state: state, attempts: statement.int(11), lastError: statement.text(12),
                created: Date(timeIntervalSince1970: statement.double(13))))
        }
        return result
    }

    private func messages(where condition: String, _ values: [SQLiteValue] = []) throws -> [MailMessageID] {
        let statement = try database.prepare("SELECT DISTINCT local_id FROM actions WHERE \(condition) ORDER BY local_id").bind(values)
        var ids: [MailMessageID] = []
        while try statement.step() { if let id = statement.text(0).flatMap(MailMessageID.init) { ids.append(id) } }
        return ids
    }

    private static func bool(_ value: Bool?) -> SQLiteValue { value.map { .int($0 ? 1 : 0) } ?? .null }
}
