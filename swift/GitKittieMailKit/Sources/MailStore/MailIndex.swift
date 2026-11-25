import Foundation
import MailClassifier
import MailCore
import MailHTML

/// A message as lists and search show it.
public struct MessageSummary: Identifiable, Hashable, Sendable {
    public var id: MailMessageID
    public var account: MailAccountID
    public var subject: String?
    public var from: MailAddress?
    public var date: Date
    public var snippet: String
    public var hasAttachments: Bool
    /// The conversation the message belongs to (see `MailIndex`, Threads).
    public var threadID: String
    public var isUnread: Bool
    public var isFlagged: Bool
}

/// A conversation as the message list shows it: its newest message in the current view, how
/// many messages it has there, and how many of those are unread.
public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public var id: String { latest.threadID }
    public var latest: MessageSummary
    public var messageCount: Int
    public var unreadCount: Int
    public var hasAttachments: Bool
    public var isFlagged: Bool
}

/// Provider flags as this device knows them. The provider is authoritative (Architecture.md);
/// the sync writes what it fetched, and the reader marks a message read when it is opened.
public struct MessageFlags: Equatable, Hashable, Sendable {
    public var seen: Bool
    public var flagged: Bool
    public init(seen: Bool = false, flagged: Bool = false) {
        self.seen = seen
        self.flagged = flagged
    }
}

/// What the index holds for one message. Built by one function from the parsed `.eml` and the
/// front matter, both on arrival and on rebuild, so a rebuilt index is the same index.
struct IndexRecord {
    /// Most references kept per message: a hostile References header cannot fan out a thread.
    static let maximumReferences = 100
    /// Most extracted attachment text indexed per message.
    static let maximumAttachmentText = 1_000_000

    var front: MessageFrontMatter
    var path: String
    var fingerprint: String
    var snippet: String
    var bodyText: String
    var attachmentText: String
    /// The List-Id, for space rules (GKM-022).
    var listID: String?
    /// A partial message (GKM-036): `path` is relative to the device folder, not the mail folder.
    var isPartial = false

    init(front: MessageFrontMatter, message: ParsedMessage, path: String, attachmentText: String = "") {
        self.front = front
        self.path = path
        self.fingerprint = ContentFingerprint.of(message)
        let body = message.textBody ?? message.htmlBody.map(HTMLText.plainText(fromHTML:)) ?? ""
        self.bodyText = body
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.snippet = String(collapsed.prefix(200))
        self.attachmentText = String(attachmentText.prefix(Self.maximumAttachmentText))
        self.listID = message.listID
    }

    /// In-Reply-To first, then References, without repeats, capped.
    var references: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in front.inReplyTo + front.references.reversed() where !id.isEmpty && id != front.messageId {
            if seen.insert(id).inserted { result.append(id) }
            if result.count == Self.maximumReferences { break }
        }
        return result
    }
}

/// A search: free text plus filters. The same value backs the search field's syntax and the
/// filter chips, so typing `from:ada is:unread` and tapping the chips give the same results.
public struct SearchQuery: Equatable, Hashable, Sendable {
    /// Words (and "quoted phrases") that must all match subject, people, body or attachments.
    public var text: String
    /// Words that must match a sender or recipient (name or address).
    public var participant: String?
    public var account: MailAccountID?
    /// A provider folder (IMAP mailbox) the message is in.
    public var mailbox: String?
    /// On or after this instant.
    public var after: Date?
    /// Before this instant.
    public var before: Date?
    public var hasAttachment: Bool
    public var unreadOnly: Bool
    public var flaggedOnly: Bool
    /// Messages in this space (GKM-022), by its id.
    public var space: MailSpaceID?
    /// A category view (GKM-018): Focused, Transactions, … Messages not classified yet count
    /// as Focused, so nothing is hidden while the classifier catches up.
    public var category: MailCategory?

    public init(text: String = "", participant: String? = nil, account: MailAccountID? = nil, mailbox: String? = nil,
                after: Date? = nil, before: Date? = nil, hasAttachment: Bool = false, unreadOnly: Bool = false,
                flaggedOnly: Bool = false, space: MailSpaceID? = nil, category: MailCategory? = nil) {
        self.text = text
        self.participant = participant
        self.account = account
        self.mailbox = mailbox
        self.after = after
        self.before = before
        self.hasAttachment = hasAttachment
        self.unreadOnly = unreadOnly
        self.flaggedOnly = flaggedOnly
        self.space = space
        self.category = category
    }

    /// True when there is something to match in the full-text index.
    public var hasTextTerms: Bool {
        MailIndex.matchQuery(text) != nil || participant.flatMap { MailIndex.matchQuery($0) } != nil
    }

    /// Reads the search field's syntax: `from:` / `to:` / `with:` (participant), `has:attachment`,
    /// `is:unread`, `is:flagged`, `in:<folder>`, `after:` / `before:` (`yyyy-mm-dd`, local
    /// midnight in `calendar`), `category:<focused|transactions|updates|subscriptions|promotions|
    /// quarantine>` (singular works too). Everything else is text. Unknown `key:value` stays text.
    public static func parse(_ input: String, calendar: Calendar = .current) -> SearchQuery {
        var query = SearchQuery()
        var words: [String] = []
        var participants: [String] = []
        for token in tokens(input) {
            let lower = token.lowercased()
            guard let colon = lower.firstIndex(of: ":"), colon != lower.startIndex, !token.hasPrefix("\"") else {
                words.append(token)
                continue
            }
            let key = String(lower[..<colon])
            let value = String(token[token.index(after: token.firstIndex(of: ":")!)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch (key, value.lowercased()) {
            case ("from", _), ("to", _), ("with", _), ("cc", _):
                if value.isEmpty { words.append(token) } else { participants.append(value) }
            case ("has", "attachment"), ("has", "attachments"): query.hasAttachment = true
            case ("is", "unread"): query.unreadOnly = true
            case ("is", "flagged"), ("is", "starred"): query.flaggedOnly = true
            case ("in", _) where !value.isEmpty: query.mailbox = value
            case ("category", let name) where MailCategory(searchName: name) != nil: query.category = MailCategory(searchName: name)
            case ("after", _): if let date = day(value, calendar: calendar) { query.after = date } else { words.append(token) }
            case ("before", _): if let date = day(value, calendar: calendar) { query.before = date } else { words.append(token) }
            default: words.append(token)
            }
        }
        query.text = words.joined(separator: " ")
        query.participant = participants.isEmpty ? nil : participants.joined(separator: " ")
        return query
    }

    /// Whitespace-separated tokens; a "quoted phrase" (also after `key:`) stays one token.
    static func tokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in input {
            if character == "\"" { quoted.toggle(); current.append(character); continue }
            if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// The device-local SQLite FTS5 index (MAIL-005, MAIL-013). It is a cache of the folder: it can
/// be deleted at any time and `MailStore.rebuildIndex()` makes it again from the files (and the
/// device's own sync state for folders and flags, and its extraction cache for attachment text).
///
/// ## Threads
///
/// A thread is a connected group of messages in one account, linked only by Message-ID,
/// In-Reply-To and References (Architecture.md): never by subject, never across accounts. A
/// Message-ID that two *different* messages claim (different content fingerprints: forged, or a
/// broken sender) is ambiguous and links nothing, so a duplicate id can never merge two
/// conversations. Two copies of the same message (same fingerprint) do share it. The thread id
/// is the smallest local id in the group, so building the threads incrementally and rebuilding
/// them from scratch give the same ids.
final class MailIndex {
    static let schemaVersion = 6

    let database: SQLiteDatabase
    /// True when the file was new, damaged, or from a version without a migration path; the
    /// store then rebuilds it from the folder.
    private(set) var needsRebuild = false

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        database.countCommits(as: .index)
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
    /// because it holds nothing the folder and device state do not. 1 → 2 (threads, flags,
    /// folders, attachment text) is a rebuild on purpose: every row gains derived columns; so is
    /// 2 → 3 (List-Id, attachment names and sizes for the library, space membership; GKM-022/023).
    /// 3 → 4 adds the classification tables (GKM-017); the messages are classified afterwards,
    /// in the background, and count as Focused until then. 4 → 5 adds the winning sender rule and
    /// its disposition to each verdict (GKM-019); until a rule changes they are empty, as they
    /// were. 5 → 6 marks partial messages and the left-out parts of their attachments (GKM-036,
    /// MAIL-062); every message indexed before is complete, which is what the defaults say.
    private func migrate(from version: Int) throws -> Bool {
        for step in version..<Self.schemaVersion {
            switch step {
            case 3: try database.execute(Self.classificationSQL)
            case 4: try database.execute(Self.senderRuleColumnsSQL)
            case 5: try addPartialColumns()
            default: return false
            }
        }
        try database.setUserVersion(Self.schemaVersion)
        return true
    }

    /// Schema 5 → 6 in place (GKM-036). Each column only when missing: an index taken back to
    /// an older version (tests do that) may already have them.
    private func addPartialColumns() throws {
        func columns(_ table: String) throws -> Set<String> {
            let statement = try database.prepare("PRAGMA table_info(\(table))")
            var names = Set<String>()
            while try statement.step() { if let name = statement.text(1) { names.insert(name) } }
            return names
        }
        if try !columns("messages").contains("partial") {
            try database.execute("ALTER TABLE messages ADD COLUMN partial INTEGER NOT NULL DEFAULT 0")
        }
        if try !columns("message_blobs").contains("section") {
            try database.execute("ALTER TABLE message_blobs ADD COLUMN section TEXT")
        }
        try database.execute("CREATE INDEX IF NOT EXISTS messages_partial ON messages (account_id) WHERE partial = 1")
    }

    /// Empties the index and refills it in one transaction: `produce` hands each record to the
    /// closure it is given, then threads are computed for everything at once. If anything
    /// throws, the old contents stay.
    func replaceAll(_ produce: (_ insert: (IndexRecord) throws -> Void) throws -> Void) throws {
        try database.transaction {
            try database.execute("""
                DELETE FROM messages; DELETE FROM message_text; DELETE FROM message_refs;
                DELETE FROM message_mailboxes; DELETE FROM message_blobs; DELETE FROM message_classes;
                """)
            try produce { try insertRow($0) }
            try assignAllThreads()
        }
        needsRebuild = false
    }

    /// Runs `body` in one transaction, so many writes cost one commit (GKM-035).
    func batch<T>(_ body: () throws -> T) throws -> T {
        try database.transaction(body)
    }

    func upsert(_ record: IndexRecord) throws {
        try database.transaction {
            let id = record.front.id
            var seeds: Set<String> = [id.rawValue]
            seeds.formUnion(try threadMembers(touching: id, account: record.front.account,
                                              keys: [record.front.messageId].compactMap { $0 } + record.references))
            try insertRow(record)
            try assignThreads(seeds: seeds)
        }
    }

    func remove(_ id: MailMessageID) throws {
        try database.transaction {
            let thread = try database.prepare("SELECT thread_id FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
            let threadID = try thread.step() ? thread.text(0) : nil
            if let row = try rowID(of: id) { try database.prepare("DELETE FROM message_text WHERE rowid = ?").run([.int(row)]) }
            for table in ["messages", "message_refs", "message_mailboxes", "message_blobs", "message_classes"] {
                try database.prepare("DELETE FROM \(table) WHERE local_id = ?").run([.text(id.rawValue)])
            }
            if let threadID { try assignThreads(seeds: Set(try members(ofThread: threadID))) }
        }
    }

    private func insertRow(_ record: IndexRecord) throws {
        let front = record.front
        let id = SQLiteValue.text(front.id.rawValue)
        // Flags survive an upsert of the same message (recovery re-indexes it).
        let flags = try database.prepare("SELECT seen, flagged FROM messages WHERE local_id = ?").bind([id])
        let (seen, flagged) = try flags.step() ? (flags.int(0), flags.int(1)) : (0, 0)
        // The text row shares the message row's rowid: found and replaced without a scan
        // (`local_id` is UNINDEXED in FTS5, so a lookup by it would read the whole table).
        if let row = try rowID(of: front.id) { try database.prepare("DELETE FROM message_text WHERE rowid = ?").run([.int(row)]) }
        for table in ["message_refs", "message_blobs"] {
            try database.prepare("DELETE FROM \(table) WHERE local_id = ?").run([id])
        }
        try database.prepare("""
            INSERT OR REPLACE INTO messages
              (local_id, account_id, path, message_id, fingerprint, subject, from_name, from_address,
               sort_date, has_attachments, snippet, eml_sha256, thread_id, seen, flagged, list_id, partial)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """).run([
                id, .text(front.account.rawValue), .text(record.path), .optional(front.messageId), .text(record.fingerprint),
                .optional(front.subject), .optional(front.from.first?.name), .optional(front.from.first?.address),
                .double(front.sortDate.timeIntervalSince1970), .int(front.attachments.contains { !$0.inline } ? 1 : 0),
                .text(record.snippet), .text(front.emlSha256), id, .int(Int64(seen)), .int(Int64(flagged)), .optional(record.listID),
                .int(record.isPartial ? 1 : 0),
            ])
        let row = database.lastInsertRowID
        let participants = (front.from + front.to + front.cc).map { [$0.name, $0.address].compactMap { $0 }.joined(separator: " ") }
        try database.prepare("""
            INSERT INTO message_text (rowid, local_id, subject, participants, body, attachments, attachment_text) VALUES (?, ?, ?, ?, ?, ?, ?)
            """).run([
                .int(row), id, .text(front.subject ?? ""), .text(participants.joined(separator: " ")), .text(record.bodyText),
                .text(front.attachments.map(\.fileName).joined(separator: " ")), .text(record.attachmentText),
            ])
        let insertRef = try database.prepare("INSERT INTO message_refs (local_id, account_id, ref_id) VALUES (?, ?, ?)")
        for reference in record.references { try insertRef.run([id, .text(front.account.rawValue), .text(reference)]) }
        let insertBlob = try database.prepare("""
            INSERT OR IGNORE INTO message_blobs (local_id, blob, media_type, file_name, size, inline, content_id, section)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
        for attachment in front.attachments {
            try insertBlob.run([id, .text(attachment.blob), .text(attachment.mediaType.lowercased()), .text(attachment.fileName),
                                .int(Int64(attachment.size)), .int(attachment.inline ? 1 : 0), .optional(attachment.contentId),
                                .optional(attachment.section)])
        }
    }

    // MARK: Threads

    /// Message ids in the threads that currently hold any message linked to `keys`, ignoring
    /// ambiguity: a new message can make an id ambiguous and so split an existing thread.
    private func threadMembers(touching id: MailMessageID, account: MailAccountID, keys: [String]) throws -> Set<String> {
        var threads = Set<String>()
        let own = try database.prepare("SELECT thread_id FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        if try own.step(), let thread = own.text(0) { threads.insert(thread) }
        let statement = try database.prepare("""
            SELECT thread_id FROM messages WHERE account_id = ?1 AND message_id = ?2
            UNION SELECT m.thread_id FROM message_refs r JOIN messages m ON m.local_id = r.local_id WHERE r.account_id = ?1 AND r.ref_id = ?2
            """)
        for key in keys {
            try statement.bind([.text(account.rawValue), .text(key)])
            while try statement.step() { if let thread = statement.text(0) { threads.insert(thread) } }
        }
        var members = Set<String>()
        for thread in threads { members.formUnion(try self.members(ofThread: thread)) }
        return members
    }

    private func members(ofThread thread: String) throws -> [String] {
        let statement = try database.prepare("SELECT local_id FROM messages WHERE thread_id = ?").bind([.text(thread)])
        var ids: [String] = []
        while try statement.step() { if let id = statement.text(0) { ids.append(id) } }
        return ids
    }

    /// Recomputes the thread of every message connected to `seeds` (breadth first over the
    /// Message-ID graph) and writes the smallest local id of each group as its thread id.
    private func assignThreads(seeds: Set<String>) throws {
        let row = try database.prepare("SELECT account_id, message_id FROM messages WHERE local_id = ?")
        let refs = try database.prepare("SELECT ref_id FROM message_refs WHERE local_id = ?")
        let claimants = try database.prepare(Self.claimantsSQL)
        let linked = try database.prepare("""
            SELECT local_id FROM messages WHERE account_id = ?1 AND message_id = ?2
            UNION SELECT local_id FROM message_refs WHERE account_id = ?1 AND ref_id = ?2
            """)
        let update = try database.prepare("UPDATE messages SET thread_id = ? WHERE local_id = ?")
        var assigned = Set<String>()
        var ambiguity: [String: Bool] = [:]

        func isAmbiguous(_ account: String, _ key: String) throws -> Bool {
            let cacheKey = account + "\u{0}" + key
            if let known = ambiguity[cacheKey] { return known }
            try claimants.bind([.text(account), .text(key)])
            let result = try claimants.step() && claimants.int(0) > 1
            ambiguity[cacheKey] = result
            return result
        }

        for seed in seeds.sorted() where !assigned.contains(seed) {
            var component: Set<String> = [seed]
            var visitedKeys = Set<String>()
            var queue = [seed]
            while let current = queue.popLast() {
                try row.bind([.text(current)])
                guard try row.step(), let account = row.text(0) else { continue }
                var keys: [String] = []
                if let own = row.text(1) { keys.append(own) }
                try refs.bind([.text(current)])
                while try refs.step() { if let ref = refs.text(0) { keys.append(ref) } }
                for key in keys {
                    let node = account + "\u{0}" + key
                    guard visitedKeys.insert(node).inserted, try !isAmbiguous(account, key) else { continue }
                    try linked.bind([.text(account), .text(key)])
                    while try linked.step() {
                        if let other = linked.text(0), component.insert(other).inserted { queue.append(other) }
                    }
                }
            }
            guard let threadID = component.min() else { continue }
            for member in component { try update.run([.text(threadID), .text(member)]) }
            assigned.formUnion(component)
        }
    }

    /// How many different messages claim a Message-ID. INDEXED BY: left alone, SQLite reads the
    /// fingerprint index in order for the DISTINCT, which visits every message in the account on
    /// each call and made every arrival slower than the one before (GKM-035).
    static let claimantsSQL = """
        SELECT count(DISTINCT fingerprint) FROM messages INDEXED BY messages_by_message_id
        WHERE account_id = ? AND message_id = ?
        """

    /// Reconciliation candidates as two indexed lookups. Written as one OR over optional
    /// parameters, SQLite could use neither index and read the whole account per call (GKM-035).
    static let candidatesSQL = """
        SELECT local_id FROM messages WHERE account_id = ?1 AND message_id = ?2
        UNION SELECT local_id FROM messages WHERE account_id = ?1 AND fingerprint = ?3
        ORDER BY local_id
        """

    /// SQLite's plan for a statement, one line per step (for tests that pin index use).
    func queryPlan(_ sql: String) throws -> [String] {
        let statement = try database.prepare("EXPLAIN QUERY PLAN " + sql)
        var lines: [String] = []
        while try statement.step() { lines.append(statement.text(3) ?? "") }
        return lines
    }

    /// Every thread at once, for a rebuild: union-find over the same graph `assignThreads` walks.
    private func assignAllThreads() throws {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root { root = p }
            var node = x
            while let p = parent[node], p != root { parent[node] = root; node = p }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { if ra < rb { parent[rb] = ra } else { parent[ra] = rb } }
        }

        var ambiguous = Set<String>()
        let counts = try database.prepare("""
            SELECT account_id, message_id FROM messages WHERE message_id IS NOT NULL
            GROUP BY account_id, message_id HAVING count(DISTINCT fingerprint) > 1
            """)
        while try counts.step() { if let a = counts.text(0), let k = counts.text(1) { ambiguous.insert(a + "\u{0}" + k) } }

        // Key nodes sort after every local id (a UUID never starts with "~").
        let messages = try database.prepare("SELECT local_id, account_id, message_id FROM messages")
        var ids: [String] = []
        while try messages.step() {
            guard let id = messages.text(0), let account = messages.text(1) else { continue }
            ids.append(id)
            parent[id] = parent[id] ?? id
            if let key = messages.text(2), !ambiguous.contains(account + "\u{0}" + key) {
                let node = "~" + account + "\u{0}" + key
                parent[node] = parent[node] ?? node
                union(id, node)
            }
        }
        let references = try database.prepare("SELECT local_id, account_id, ref_id FROM message_refs")
        while try references.step() {
            guard let id = references.text(0), let account = references.text(1), let key = references.text(2),
                  !ambiguous.contains(account + "\u{0}" + key) else { continue }
            let node = "~" + account + "\u{0}" + key
            parent[node] = parent[node] ?? node
            union(id, node)
        }
        let update = try database.prepare("UPDATE messages SET thread_id = ? WHERE local_id = ?")
        for id in ids { try update.run([.text(find(id)), .text(id)]) }
    }

    // MARK: Flags, folders, attachment text

    func setFlags(_ flags: MessageFlags, for id: MailMessageID) throws {
        try database.prepare("UPDATE messages SET seen = ?, flagged = ? WHERE local_id = ?")
            .run([.int(flags.seen ? 1 : 0), .int(flags.flagged ? 1 : 0), .text(id.rawValue)])
    }

    /// Replaces the folders a message is in.
    func setMailboxes(_ mailboxes: Set<String>, for id: MailMessageID, account: MailAccountID) throws {
        try database.transaction {
            try database.prepare("DELETE FROM message_mailboxes WHERE local_id = ?").run([.text(id.rawValue)])
            let insert = try database.prepare("INSERT OR IGNORE INTO message_mailboxes (local_id, account_id, mailbox) VALUES (?, ?, ?)")
            for mailbox in mailboxes.sorted() { try insert.run([.text(id.rawValue), .text(account.rawValue), .text(mailbox)]) }
        }
    }

    /// Replaces a folder's members (after a UIDVALIDITY change voided its UIDs).
    func setMembers(_ ids: [MailMessageID], ofMailbox mailbox: String, account: MailAccountID) throws {
        try database.transaction {
            try database.prepare("DELETE FROM message_mailboxes WHERE account_id = ? AND mailbox = ?").run([.text(account.rawValue), .text(mailbox)])
            let insert = try database.prepare("INSERT OR IGNORE INTO message_mailboxes (local_id, account_id, mailbox) VALUES (?, ?, ?)")
            for id in ids { try insert.run([.text(id.rawValue), .text(account.rawValue), .text(mailbox)]) }
        }
    }

    /// Bulk restore of device state after a rebuild.
    func restore(flags: [MailMessageID: MessageFlags], locations: [(MailMessageID, String)], account: MailAccountID) throws {
        try database.transaction {
            let setFlags = try database.prepare("UPDATE messages SET seen = ?, flagged = ? WHERE local_id = ? AND account_id = ?")
            for (id, value) in flags {
                try setFlags.run([.int(value.seen ? 1 : 0), .int(value.flagged ? 1 : 0), .text(id.rawValue), .text(account.rawValue)])
            }
            let insert = try database.prepare("""
                INSERT OR IGNORE INTO message_mailboxes (local_id, account_id, mailbox)
                SELECT local_id, account_id, ? FROM messages WHERE local_id = ? AND account_id = ?
                """)
            for (id, mailbox) in locations { try insert.run([.text(mailbox), .text(id.rawValue), .text(account.rawValue)]) }
        }
    }

    /// Distinct attachment blobs of the given media types, oldest message first, that are not in
    /// `done`: what still needs text extraction.
    func blobs(ofTypes mediaTypes: Set<String>, excluding done: Set<String>, limit: Int) throws -> [(blob: String, mediaType: String)] {
        guard !mediaTypes.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: mediaTypes.count).joined(separator: ",")
        // A part still at the provider has no bytes to extract from yet (GKM-036).
        let statement = try database.prepare("""
            SELECT DISTINCT blob, media_type FROM message_blobs WHERE media_type IN (\(placeholders)) AND blob NOT LIKE 'part:%' ORDER BY blob
            """)
            .bind(mediaTypes.sorted().map(SQLiteValue.text))
        var result: [(String, String)] = []
        while try statement.step(), result.count < limit {
            if let blob = statement.text(0), let type = statement.text(1), !done.contains(blob) { result.append((blob, type)) }
        }
        return result
    }

    /// Messages that carry `blob`, with the blobs each carries, for re-indexing attachment text.
    func messages(withBlob blob: String) throws -> [(id: MailMessageID, blobs: [String])] {
        let statement = try database.prepare("SELECT DISTINCT local_id FROM message_blobs WHERE blob = ? ORDER BY local_id").bind([.text(blob)])
        var ids: [MailMessageID] = []
        while try statement.step() { if let id = statement.text(0).flatMap(MailMessageID.init) { ids.append(id) } }
        let blobs = try database.prepare("SELECT blob FROM message_blobs WHERE local_id = ? ORDER BY rowid")
        return try ids.map { id in
            try blobs.bind([.text(id.rawValue)])
            var list: [String] = []
            while try blobs.step() { if let b = blobs.text(0) { list.append(b) } }
            return (id, list)
        }
    }

    func setAttachmentText(_ text: String, for id: MailMessageID) throws {
        guard let row = try rowID(of: id) else { return }
        try database.prepare("UPDATE message_text SET attachment_text = ? WHERE rowid = ?")
            .run([.text(String(text.prefix(IndexRecord.maximumAttachmentText))), .int(row)])
    }

    private func rowID(of id: MailMessageID) throws -> Int64? {
        let statement = try database.prepare("SELECT rowid FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? Int64(statement.int(0)) : nil
    }

    // MARK: Reading

    func path(of id: MailMessageID) throws -> String? {
        try location(of: id)?.path
    }

    /// Where a message's file is: in the mail folder, or (a partial message) in the device folder.
    func location(of id: MailMessageID) throws -> (path: String, isPartial: Bool)? {
        let statement = try database.prepare("SELECT path, partial FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        guard try statement.step(), let path = statement.text(0) else { return nil }
        return (path, statement.int(1) != 0)
    }

    func account(of id: MailMessageID) throws -> MailAccountID? {
        let statement = try database.prepare("SELECT account_id FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? statement.text(0).map(MailAccountID.init) : nil
    }

    func containsOriginal(sha256: String, account: MailAccountID) throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM messages WHERE account_id = ? AND eml_sha256 = ? LIMIT 1")
            .bind([.text(account.rawValue), .text(sha256)])
        return try statement.step()
    }

    func count() throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM messages")
        return try statement.step() ? statement.int(0) : 0
    }

    func unreadCount(account: MailAccountID?, mailbox: String?) throws -> Int {
        let (clause, values) = Self.filterClause(SearchQuery(account: account, mailbox: mailbox, unreadOnly: true))
        let statement = try database.prepare("SELECT count(*) FROM messages m WHERE \(clause)").bind(values)
        return try statement.step() ? statement.int(0) : 0
    }

    func summaries(account: MailAccountID?, limit: Int, offset: Int) throws -> [MessageSummary] {
        try summaries(matching: SearchQuery(account: account), limit: limit, offset: offset)
    }

    /// Messages matching the filters (and text, if any): best text matches first, then newest.
    func summaries(matching query: SearchQuery, limit: Int, offset: Int = 0) throws -> [MessageSummary] {
        let (clause, filterValues) = Self.filterClause(query)
        if let match = Self.ftsQuery(query) {
            let sql = """
                SELECT \(Self.summaryColumns) FROM message_text t CROSS JOIN messages m ON m.rowid = t.rowid
                WHERE message_text MATCH ? AND \(clause)
                ORDER BY bm25(message_text, 0.0, 4.0, 2.0, 1.0, 1.0, 0.5), m.sort_date DESC, m.local_id LIMIT ? OFFSET ?
                """
            return try readSummaries(database.prepare(sql).bind([.text(match)] + filterValues + [.int(Int64(limit)), .int(Int64(offset))]))
        }
        let sql = "SELECT \(Self.summaryColumns) FROM messages m WHERE \(clause) ORDER BY m.sort_date DESC, m.local_id LIMIT ? OFFSET ?"
        return try readSummaries(database.prepare(sql).bind(filterValues + [.int(Int64(limit)), .int(Int64(offset))]))
    }

    func search(_ text: String, account: MailAccountID?, limit: Int) throws -> [MessageSummary] {
        let query = SearchQuery(text: text, account: account)
        guard query.hasTextTerms else { return [] }
        return try summaries(matching: query, limit: limit)
    }

    /// Conversations in a view, newest activity first. Counts are within the view's filters.
    ///
    /// Walks the view's messages newest first (on the date index) until it has a page of
    /// distinct threads, then counts just those threads: the cost follows the page, not the
    /// mailbox (a window function over every row took 0.6 s at 100,000 messages).
    func threads(matching query: SearchQuery, limit: Int, offset: Int) throws -> [ThreadSummary] {
        let (clause, values) = Self.filterClause(query)
        let walk = try database.prepare("SELECT \(Self.summaryColumns) FROM messages m WHERE \(clause) ORDER BY m.sort_date DESC, m.local_id")
            .bind(values)
        var seen = Set<String>()
        var latest: [MessageSummary] = []
        while latest.count < offset + limit, try walk.step() {
            guard let summary = Self.summary(walk), seen.insert(summary.threadID).inserted else { continue }
            latest.append(summary)
        }
        let page = Array(latest.dropFirst(offset))
        guard !page.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: page.count).joined(separator: ",")
        let counts = try database.prepare("""
            SELECT m.thread_id, count(*), sum(1 - m.seen), max(m.has_attachments), max(m.flagged) FROM messages m
            WHERE m.thread_id IN (\(placeholders)) AND \(clause) GROUP BY m.thread_id
            """).bind(page.map { .text($0.threadID) } + values)
        var totals: [String: (Int, Int, Bool, Bool)] = [:]
        while try counts.step() {
            if let thread = counts.text(0) { totals[thread] = (counts.int(1), counts.int(2), counts.int(3) != 0, counts.int(4) != 0) }
        }
        return page.map { summary in
            let total = totals[summary.threadID] ?? (1, summary.isUnread ? 1 : 0, summary.hasAttachments, summary.isFlagged)
            return ThreadSummary(latest: summary, messageCount: total.0, unreadCount: total.1, hasAttachments: total.2, isFlagged: total.3)
        }
    }

    /// Every message of a thread, oldest first.
    func thread(_ threadID: String) throws -> [MessageSummary] {
        let statement = try database.prepare("SELECT \(Self.summaryColumns) FROM messages m WHERE m.thread_id = ? ORDER BY m.sort_date, m.local_id")
            .bind([.text(threadID)])
        return try readSummaries(statement)
    }

    /// The folders that hold messages in an account, by name.
    func mailboxes(account: MailAccountID) throws -> [String] {
        let statement = try database.prepare("SELECT DISTINCT mailbox FROM message_mailboxes WHERE account_id = ? ORDER BY mailbox")
            .bind([.text(account.rawValue)])
        var names: [String] = []
        while try statement.step() { if let name = statement.text(0) { names.append(name) } }
        return names
    }

    /// Messages in an account whose Message-ID or content fingerprint matches: candidates for
    /// reconciliation after a move or a UIDVALIDITY reset, never automatic merges.
    func candidates(account: MailAccountID, messageID: String?, fingerprint: String?) throws -> [MailMessageID] {
        let statement = try database.prepare(Self.candidatesSQL).bind([.text(account.rawValue), .optional(messageID), .optional(fingerprint)])
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }

    // MARK: Query building

    /// The user's words as an FTS5 query: each word quoted (so FTS syntax in the input is just
    /// text) and matched as a prefix; a "quoted phrase" stays a phrase; all must match.
    static func matchQuery(_ text: String, column: String? = nil) -> String? {
        var parts: [String] = []
        for token in SearchQuery.tokens(text) {
            let phrase = token.hasPrefix("\"")
            let words = token.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            let terms = phrase ? ["\"\(words.joined(separator: " "))\""] : words.map { "\"\($0)\"*" }
            parts.append(contentsOf: terms.map { term in column.map { "\($0) : \(term)" } ?? term })
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func ftsQuery(_ query: SearchQuery) -> String? {
        let parts = [matchQuery(query.text), query.participant.flatMap { matchQuery($0, column: "participants") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The non-text filters as a WHERE clause over `messages m`, with its values.
    static func filterClause(_ query: SearchQuery) -> (String, [SQLiteValue]) {
        var clauses = ["1"]
        var values: [SQLiteValue] = []
        if let account = query.account { clauses.append("m.account_id = ?"); values.append(.text(account.rawValue)) }
        if let mailbox = query.mailbox {
            clauses.append("EXISTS (SELECT 1 FROM message_mailboxes b WHERE b.local_id = m.local_id AND b.mailbox = ? COLLATE NOCASE)")
            values.append(.text(mailbox))
        }
        if let after = query.after { clauses.append("m.sort_date >= ?"); values.append(.double(after.timeIntervalSince1970)) }
        if let before = query.before { clauses.append("m.sort_date < ?"); values.append(.double(before.timeIntervalSince1970)) }
        if query.hasAttachment { clauses.append("m.has_attachments = 1") }
        if query.unreadOnly { clauses.append("m.seen = 0") }
        if query.flaggedOnly { clauses.append("m.flagged = 1") }
        if let space = query.space {
            clauses.append("EXISTS (SELECT 1 FROM space_members s WHERE s.local_id = m.local_id AND s.space_id = ?)")
            values.append(.text(space.rawValue))
        }
        if let category = query.category {
            let (clause, categoryValues) = categoryClause(category)
            clauses.append(clause)
            values += categoryValues
        }
        return (clauses.joined(separator: " AND "), values)
    }

    static let summaryColumns = """
        m.local_id, m.account_id, m.subject, m.from_name, m.from_address, m.sort_date, m.snippet, m.has_attachments, \
        m.thread_id, m.seen, m.flagged
        """

    static func summary(_ statement: SQLiteDatabase.Statement) -> MessageSummary? {
        guard let raw = statement.text(0), let id = MailMessageID(raw), let account = statement.text(1) else { return nil }
        let from = statement.text(4).map { MailAddress(name: statement.text(3), address: $0) }
        return MessageSummary(id: id, account: MailAccountID(account), subject: statement.text(2), from: from,
                              date: Date(timeIntervalSince1970: statement.double(5)), snippet: statement.text(6) ?? "",
                              hasAttachments: statement.int(7) != 0, threadID: statement.text(8) ?? raw,
                              isUnread: statement.int(9) == 0, isFlagged: statement.int(10) != 0)
    }

    func readSummaries(_ statement: SQLiteDatabase.Statement) throws -> [MessageSummary] {
        var result: [MessageSummary] = []
        while try statement.step() { if let summary = Self.summary(statement) { result.append(summary) } }
        return result
    }

    private static let dropSQL = """
        DROP TABLE IF EXISTS messages;
        DROP TABLE IF EXISTS message_text;
        DROP TABLE IF EXISTS message_refs;
        DROP TABLE IF EXISTS message_mailboxes;
        DROP TABLE IF EXISTS message_blobs;
        DROP TABLE IF EXISTS space_members;
        DROP TABLE IF EXISTS message_classes;
        DROP TABLE IF EXISTS correspondents;
        DROP TABLE IF EXISTS authenticated_domains;
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
          eml_sha256 TEXT NOT NULL,
          thread_id TEXT NOT NULL,
          seen INTEGER NOT NULL DEFAULT 0,
          flagged INTEGER NOT NULL DEFAULT 0,
          list_id TEXT
        );
        CREATE INDEX messages_by_date ON messages (sort_date DESC);
        CREATE INDEX messages_by_account_date ON messages (account_id, sort_date DESC);
        CREATE INDEX messages_by_message_id ON messages (account_id, message_id);
        CREATE INDEX messages_by_fingerprint ON messages (account_id, fingerprint);
        CREATE INDEX messages_by_thread ON messages (thread_id, sort_date);
        CREATE INDEX messages_by_original ON messages (account_id, eml_sha256);
        CREATE TABLE message_refs (local_id TEXT NOT NULL, account_id TEXT NOT NULL, ref_id TEXT NOT NULL);
        CREATE INDEX message_refs_by_ref ON message_refs (account_id, ref_id);
        CREATE INDEX message_refs_by_message ON message_refs (local_id);
        CREATE TABLE message_mailboxes (
          local_id TEXT NOT NULL, account_id TEXT NOT NULL, mailbox TEXT NOT NULL, PRIMARY KEY (local_id, mailbox)
        );
        CREATE INDEX message_mailboxes_by_mailbox ON message_mailboxes (account_id, mailbox);
        CREATE INDEX messages_by_list ON messages (list_id);
        CREATE TABLE message_blobs (
          local_id TEXT NOT NULL, blob TEXT NOT NULL, media_type TEXT NOT NULL,
          file_name TEXT NOT NULL DEFAULT '', size INTEGER NOT NULL DEFAULT 0, inline INTEGER NOT NULL DEFAULT 0, content_id TEXT,
          PRIMARY KEY (local_id, blob)
        );
        CREATE INDEX message_blobs_by_blob ON message_blobs (blob);
        CREATE TABLE space_members (space_id TEXT NOT NULL, local_id TEXT NOT NULL, PRIMARY KEY (space_id, local_id));
        CREATE INDEX space_members_by_message ON space_members (local_id);
        CREATE VIRTUAL TABLE message_text USING fts5(
          local_id UNINDEXED, subject, participants, body, attachments, attachment_text,
          tokenize = 'unicode61 remove_diacritics 2'
        );
        """ + classificationSQL + senderRuleColumnsSQL + partialColumnsSQL

    /// Schema 6 (GKM-036): `partial` is 1 for a message whose original is not stored yet (its
    /// `path` is then in the device folder); a part left at the provider has its IMAP `section`.
    static let partialColumnsSQL = """
        ALTER TABLE messages ADD COLUMN partial INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE message_blobs ADD COLUMN section TEXT;
        CREATE INDEX IF NOT EXISTS messages_partial ON messages (account_id) WHERE partial = 1;
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
            (message.textBody ?? message.htmlBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return Hashing.sha256Hex(Data(parts.joined(separator: "\n").utf8))
    }
}
