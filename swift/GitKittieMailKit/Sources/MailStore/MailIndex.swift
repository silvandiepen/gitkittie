import Foundation
import MailCore

/// A message as lists and search show it.
public struct MessageSummary: Identifiable, Hashable, Sendable {
    public var id: MailMessageID
    public var account: MailAccountID
    public var subject: String?
    public var from: MailAddress?
    public var date: Date
    public var snippet: String
    public var hasAttachments: Bool
}

/// What the index holds for one message. Built by one function from the parsed `.eml` and the
/// front matter, both on arrival and on rebuild, so a rebuilt index is the same index.
struct IndexRecord {
    var front: MessageFrontMatter
    var path: String
    var fingerprint: String
    var snippet: String
    var bodyText: String

    init(front: MessageFrontMatter, message: ParsedMessage, path: String) {
        self.front = front
        self.path = path
        self.fingerprint = ContentFingerprint.of(message)
        let body = message.textBody ?? ""
        self.bodyText = body
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.snippet = String(collapsed.prefix(200))
    }
}

/// The device-local SQLite FTS5 index (MAIL-005, MAIL-013). It is a cache of the folder: it can
/// be deleted at any time and `MailStore.rebuildIndex()` makes it again from the files.
final class MailIndex {
    static let schemaVersion = 1

    private let database: SQLiteDatabase
    /// True when the file was new, damaged, or from a version without a migration path; the
    /// store then rebuilds it from the folder.
    private(set) var needsRebuild = false

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        let version = try database.userVersion
        if version == Self.schemaVersion { return }
        if version != 0, version < Self.schemaVersion, try migrate(from: version) { return }
        // New, from a newer app, or no way forward: start empty and let the store refill it.
        try database.execute(Self.dropSQL)
        try database.transaction {
            try database.execute(Self.createSQL)
            try database.setUserVersion(Self.schemaVersion)
        }
        needsRebuild = true
    }

    /// Migration hook: bring an index at `version` up to `schemaVersion`, one step at a time.
    /// Returns false when a step is missing; the index is then rebuilt, which is always safe
    /// because it holds nothing the folder does not. There are no steps yet (schema 1).
    private func migrate(from version: Int) throws -> Bool {
        for step in version..<Self.schemaVersion {
            switch step {
            // case 1: try database.execute("ALTER TABLE …")   (1 → 2)
            default: return false
            }
        }
        try database.setUserVersion(Self.schemaVersion)
        return true
    }

    /// Empties the index and refills it in one transaction: `produce` hands each record to the
    /// closure it is given. If anything throws, the old contents stay.
    func replaceAll(_ produce: (_ insert: (IndexRecord) throws -> Void) throws -> Void) throws {
        try database.transaction {
            try database.execute("DELETE FROM messages; DELETE FROM message_text;")
            try produce { try insert($0) }
        }
        needsRebuild = false
    }

    func upsert(_ record: IndexRecord) throws {
        try database.transaction { try insert(record) }
    }

    func remove(_ id: MailMessageID) throws {
        try database.transaction {
            try database.prepare("DELETE FROM messages WHERE local_id = ?").run([.text(id.rawValue)])
            try database.prepare("DELETE FROM message_text WHERE local_id = ?").run([.text(id.rawValue)])
        }
    }

    private func insert(_ record: IndexRecord) throws {
        let front = record.front
        let id = SQLiteValue.text(front.id.rawValue)
        try database.prepare("DELETE FROM message_text WHERE local_id = ?").run([id])
        try database.prepare("""
            INSERT OR REPLACE INTO messages
              (local_id, account_id, path, message_id, fingerprint, subject, from_name, from_address,
               sort_date, has_attachments, snippet, eml_sha256)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """).run([
                id, .text(front.account.rawValue), .text(record.path), .optional(front.messageId), .text(record.fingerprint),
                .optional(front.subject), .optional(front.from.first?.name), .optional(front.from.first?.address),
                .double(front.sortDate.timeIntervalSince1970), .int(front.attachments.isEmpty ? 0 : 1),
                .text(record.snippet), .text(front.emlSha256),
            ])
        let participants = (front.from + front.to + front.cc).map { [$0.name, $0.address].compactMap { $0 }.joined(separator: " ") }
        try database.prepare("INSERT INTO message_text (local_id, subject, participants, body, attachments) VALUES (?, ?, ?, ?, ?)").run([
            id, .text(front.subject ?? ""), .text(participants.joined(separator: " ")), .text(record.bodyText),
            .text(front.attachments.map(\.fileName).joined(separator: " ")),
        ])
    }

    // MARK: Reading

    func path(of id: MailMessageID) throws -> String? {
        let statement = try database.prepare("SELECT path FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? statement.text(0) : nil
    }

    func count() throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM messages")
        return try statement.step() ? statement.int(0) : 0
    }

    func summaries(account: MailAccountID?, limit: Int, offset: Int) throws -> [MessageSummary] {
        var sql = "SELECT \(Self.summaryColumns) FROM messages m"
        var values: [SQLiteValue] = []
        if let account { sql += " WHERE m.account_id = ?"; values.append(.text(account.rawValue)) }
        sql += " ORDER BY m.sort_date DESC, m.local_id LIMIT ? OFFSET ?"
        values += [.int(Int64(limit)), .int(Int64(offset))]
        return try readSummaries(database.prepare(sql).bind(values))
    }

    /// Full-text search. Every word must match (as a prefix); best matches first, then newest,
    /// then by id, so equal scores always come back in the same order.
    func search(_ text: String, account: MailAccountID?, limit: Int) throws -> [MessageSummary] {
        guard let query = Self.matchQuery(text) else { return [] }
        var sql = """
            SELECT \(Self.summaryColumns) FROM message_text t JOIN messages m ON m.local_id = t.local_id
            WHERE message_text MATCH ?
            """
        var values: [SQLiteValue] = [.text(query)]
        if let account { sql += " AND m.account_id = ?"; values.append(.text(account.rawValue)) }
        sql += " ORDER BY bm25(message_text, 0.0, 4.0, 2.0, 1.0, 1.0), m.sort_date DESC, m.local_id LIMIT ?"
        values.append(.int(Int64(limit)))
        return try readSummaries(database.prepare(sql).bind(values))
    }

    /// Messages in an account whose Message-ID or content fingerprint matches: candidates for
    /// reconciliation after a move or a UIDVALIDITY reset, never automatic merges.
    func candidates(account: MailAccountID, messageID: String?, fingerprint: String?) throws -> [MailMessageID] {
        let statement = try database.prepare("""
            SELECT local_id FROM messages WHERE account_id = ?
              AND ((? IS NOT NULL AND message_id = ?) OR (? IS NOT NULL AND fingerprint = ?))
            ORDER BY local_id
            """).bind([.text(account.rawValue), .optional(messageID), .optional(messageID), .optional(fingerprint), .optional(fingerprint)])
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }

    /// The user's words as an FTS5 query: each word quoted (so FTS syntax in the input is just
    /// text) and matched as a prefix; all must match.
    static func matchQuery(_ text: String) -> String? {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static let summaryColumns = "m.local_id, m.account_id, m.subject, m.from_name, m.from_address, m.sort_date, m.snippet, m.has_attachments"

    private func readSummaries(_ statement: SQLiteDatabase.Statement) throws -> [MessageSummary] {
        var result: [MessageSummary] = []
        while try statement.step() {
            guard let raw = statement.text(0), let id = MailMessageID(raw), let account = statement.text(1) else { continue }
            let from = statement.text(4).map { MailAddress(name: statement.text(3), address: $0) }
            result.append(MessageSummary(id: id, account: MailAccountID(account), subject: statement.text(2), from: from,
                                         date: Date(timeIntervalSince1970: statement.double(5)), snippet: statement.text(6) ?? "",
                                         hasAttachments: statement.int(7) != 0))
        }
        return result
    }

    private static let dropSQL = """
        DROP TABLE IF EXISTS messages;
        DROP TABLE IF EXISTS message_text;
        """

    private static let createSQL = """
        CREATE TABLE messages (
          local_id TEXT PRIMARY KEY,
          account_id TEXT NOT NULL,
          path TEXT NOT NULL,
          message_id TEXT,
          fingerprint TEXT NOT NULL,
          subject TEXT,
          from_name TEXT,
          from_address TEXT,
          sort_date REAL NOT NULL,
          has_attachments INTEGER NOT NULL,
          snippet TEXT NOT NULL,
          eml_sha256 TEXT NOT NULL
        );
        CREATE INDEX messages_by_account_date ON messages (account_id, sort_date DESC);
        CREATE INDEX messages_by_message_id ON messages (account_id, message_id);
        CREATE INDEX messages_by_fingerprint ON messages (account_id, fingerprint);
        CREATE VIRTUAL TABLE message_text USING fts5(
          local_id UNINDEXED, subject, participants, body, attachments,
          tokenize = 'unicode61 remove_diacritics 2'
        );
        """
}

/// A content fingerprint: the same message seen twice (in two mailboxes, after a UIDVALIDITY
/// reset, without a Message-ID) gives the same value; a reconciliation signal, not an identity.
/// Built from the Date, sender, subject and plain-text body, not from the raw bytes, because
/// servers add and rewrite trace headers.
enum ContentFingerprint {
    static func of(_ message: ParsedMessage) -> String {
        let parts = [
            "v1",
            message.date.map { String(Int64($0.timeIntervalSince1970)) } ?? "",
            message.from.map { $0.address.lowercased() }.joined(separator: ","),
            message.subject ?? "",
            (message.textBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return Hashing.sha256Hex(Data(parts.joined(separator: "\n").utf8))
    }
}
