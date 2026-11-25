import Foundation
import MailCore

// The index's side of spaces (GKM-022). `space_members` is a copy of the membership in
// `Mail/spaces/*.json`, made so a space can filter the list, search and the attachment library
// in SQL. Like everything in the index it is rebuilt from the folder.

/// What the index knows about a message that a space records alongside its id.
struct MessageIdentity {
    var id: MailMessageID
    var account: MailAccountID
    var messageID: String?
    var emlSha256: String
}

extension MailIndex {
    /// Replaces the members of every space at once.
    func replaceSpaceMembers(_ members: [MailSpaceID: Set<MailMessageID>]) throws {
        try database.transaction {
            try database.execute("DELETE FROM space_members")
            let insert = try database.prepare("INSERT OR IGNORE INTO space_members (space_id, local_id) VALUES (?, ?)")
            for (space, ids) in members {
                for id in ids { try insert.run([.text(space.rawValue), .text(id.rawValue)]) }
            }
        }
    }

    /// Replaces one space's members (nil removes the space).
    func setSpaceMembers(_ ids: Set<MailMessageID>?, of space: MailSpaceID) throws {
        try database.transaction {
            try database.prepare("DELETE FROM space_members WHERE space_id = ?").run([.text(space.rawValue)])
            let insert = try database.prepare("INSERT OR IGNORE INTO space_members (space_id, local_id) VALUES (?, ?)")
            for id in ids ?? [] { try insert.run([.text(space.rawValue), .text(id.rawValue)]) }
        }
    }

    /// The spaces a message is in.
    func spaces(containing id: MailMessageID) throws -> Set<MailSpaceID> {
        let statement = try database.prepare("SELECT space_id FROM space_members WHERE local_id = ?").bind([.text(id.rawValue)])
        var result = Set<MailSpaceID>()
        while try statement.step() { if let raw = statement.text(0), let space = MailSpaceID(raw) { result.insert(space) } }
        return result
    }

    /// How many stored messages each space holds (members whose message is gone are not counted,
    /// nor those only in Trash or Junk, which the space's view leaves out; MAIL-102).
    func spaceCounts() throws -> [MailSpaceID: (messages: Int, unread: Int)] {
        let statement = try database.prepare("""
            SELECT s.space_id, count(*), sum(1 - m.seen) FROM space_members s JOIN messages m ON m.local_id = s.local_id
            WHERE \(Self.notTrashOrJunk) GROUP BY s.space_id
            """)
        var result: [MailSpaceID: (Int, Int)] = [:]
        while try statement.step() {
            if let raw = statement.text(0), let space = MailSpaceID(raw) { result[space] = (statement.int(1), statement.int(2)) }
        }
        return result
    }

    /// Account, Message-ID and original hash of stored messages; ids not in the index are left out.
    func identities(of ids: [MailMessageID]) throws -> [MessageIdentity] {
        let statement = try database.prepare("SELECT account_id, message_id, eml_sha256 FROM messages WHERE local_id = ?")
        var result: [MessageIdentity] = []
        for id in ids {
            _ = try statement.bind([.text(id.rawValue)])
            if try statement.step(), let account = statement.text(0), let sha = statement.text(2) {
                result.append(MessageIdentity(id: id, account: MailAccountID(account), messageID: statement.text(1), emlSha256: sha))
            }
        }
        return result
    }

    /// Every message id in a thread.
    func ids(inThread threadID: String) throws -> [MailMessageID] {
        let statement = try database.prepare("SELECT local_id FROM messages WHERE thread_id = ? ORDER BY sort_date, local_id")
            .bind([.text(threadID)])
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }

    // MARK: Rules

    /// The ids of every stored message a rule matches; empty for a rule with no conditions.
    func ids(matching rule: SpaceRule) throws -> [MailMessageID] {
        guard let (clause, values) = Self.ruleClause(rule) else { return [] }
        let statement = try database.prepare("SELECT m.local_id FROM messages m WHERE \(clause) ORDER BY m.sort_date DESC, m.local_id")
            .bind(values)
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }

    /// The newest messages a rule matches.
    func summaries(matching rule: SpaceRule, limit: Int) throws -> [MessageSummary] {
        guard let (clause, values) = Self.ruleClause(rule) else { return [] }
        let statement = try database.prepare("""
            SELECT \(Self.summaryColumns) FROM messages m WHERE \(clause) ORDER BY m.sort_date DESC, m.local_id LIMIT ?
            """).bind(values + [.int(Int64(limit))])
        return try readSummaries(statement)
    }

    /// A rule as a WHERE clause over `messages m`; nil when it sets no message condition.
    static func ruleClause(_ rule: SpaceRule) -> (String, [SQLiteValue])? {
        let rule = rule.normalized
        guard !rule.isEmpty else { return nil }
        var clauses: [String] = []
        var values: [SQLiteValue] = []
        if let sender = rule.sender {
            clauses.append("lower(m.from_address) = ?")
            values.append(.text(sender))
        }
        if let domain = rule.domain {
            // The part after the last "@": the domain itself or a subdomain of it.
            let host = "lower(substr(m.from_address, instr(m.from_address, '@') + 1))"
            clauses.append("(instr(m.from_address, '@') > 0 AND (\(host) = ? OR \(host) LIKE ? ESCAPE '\\'))")
            values += [.text(domain), .text("%." + likeEscaped(domain))]
        }
        if let list = rule.list {
            clauses.append("m.list_id = ?")
            values.append(.text(list))
        }
        if let words = rule.subjectWords {
            guard let match = matchQuery(words, column: "subject") else { return nil }
            clauses.append("m.rowid IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)")
            values.append(.text(match))
        }
        if let account = rule.account {
            clauses.append("m.account_id = ?")
            values.append(.text(account.rawValue))
        }
        return (clauses.joined(separator: " AND "), values)
    }
}

extension MailIndex {
    /// Summaries by id, in the order given.
    func summaries(ids: [MailMessageID]) throws -> [MessageSummary] {
        let statement = try database.prepare("SELECT \(Self.summaryColumns) FROM messages m WHERE m.local_id = ?")
        var result: [MessageSummary] = []
        for id in ids {
            try statement.bind([.text(id.rawValue)])
            if try statement.step(), let summary = Self.summary(statement) { result.append(summary) }
        }
        return result
    }
}
