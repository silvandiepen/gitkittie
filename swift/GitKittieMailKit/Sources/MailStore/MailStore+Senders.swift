import Foundation
import MailClassifier
import MailCore

// Sender and list rules in the store (GKM-019; MAIL-054, MAIL-055). A rule is applied where the
// classifier's verdict is made, so every path that classifies (arrival, rebuild, a new rule set,
// a correction) applies it the same way, and a preview runs exactly that path without saving.

/// Where a message is, as a rule preview compares it.
public struct SenderPlacement: Sendable, Equatable, Hashable {
    public var home: MailCategory
    public var purpose: MailPurpose
    public var disposition: SenderDisposition?
    public var rule: String?

    public init(home: MailCategory, purpose: MailPurpose, disposition: SenderDisposition?, rule: String?) {
        self.home = home
        self.purpose = purpose
        self.disposition = disposition
        self.rule = rule
    }
}

/// What a set of rules does to every message they could touch: the dry run you see before a
/// rule is saved, and, after applying, the proof that it did what the preview said.
public struct SenderRulePreview: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: MailMessageID
        public var account: MailAccountID
        public var subject: String?
        public var from: MailAddress?
        public var date: Date
        public var fingerprint: String
        public var before: SenderPlacement?
        public var after: SenderPlacement
        /// Why the winning rule left it as it was, if it did.
        public var protection: SenderRuleProtection?
        /// You took it out of the rule.
        public var isExcluded: Bool

        /// It would move: another view, purpose or disposition (which rule decided alone is no move).
        public var changes: Bool {
            before?.home != after.home || before?.purpose != after.purpose || before?.disposition != after.disposition
        }
    }

    public var items: [Item]

    public var changed: [Item] { items.filter(\.changes) }
    public var protected: [Item] { items.filter { $0.protection != nil } }
}

/// Which rule won for a message, why, and which others also matched (in your order).
public struct SenderRuleExplanation: Sendable, Equatable {
    public var winner: SenderRule
    /// 1-based position in your rule order.
    public var position: Int
    public var effect: SenderRuleEffect
    public var alsoMatched: [SenderRule]
}

/// The newest message of a sender or list, with what an unsubscribe needs to judge it. Read
/// from the stored original; nothing is fetched (ThreatModel §9).
public struct SenderListHeaders: Sendable, Equatable {
    public var message: MailMessageID
    public var account: MailAccountID
    public var verdict: StoredVerdict?
    /// List-Unsubscribe, List-Unsubscribe-Post, List-ID, List-Post: the raw values.
    public var headers: [String: String]
    /// The addresses it was sent to (To and Cc), for the From of a mailto unsubscribe.
    public var recipients: [MailAddress]
}

/// Local open history, per sender or list, on this device only.
struct SenderOpenRecord: Codable, Equatable {
    var opens: Int
    var lastOpened: Date
}

struct SenderOpenHistory: Codable, Equatable {
    var version = 1
    var senders: [String: SenderOpenRecord] = [:]

    static func url(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("preferences", isDirectory: true).appendingPathComponent("open-history.json")
    }
}

/// A verdict worked out but not saved yet.
struct PlannedVerdict {
    var stored: StoredVerdict
    var fromDomain: String?
    var fingerprint: String
    var winner: SenderRule?
    var effect: SenderRuleEffect?
    var alsoMatched: [SenderRule]
}

extension MailStore {
    // MARK: Directory

    /// Every sender and list with volume, categories, dates and the local open history.
    public func senders(account: MailAccountID? = nil, now: Date = Date()) throws -> [SenderSummary] {
        let history = try openHistory()
        return try index.senderDirectory(account: account, now: now).map { summary in
            var summary = summary
            if let record = history.senders[summary.id] {
                summary.opens = record.opens
                summary.lastOpened = record.lastOpened
            }
            return summary
        }
    }

    /// A sender's or list's messages, newest first.
    public func messages(of scope: SenderScope, account: MailAccountID, limit: Int = 200) throws -> [MessageSummary] {
        let ids = try index.members(of: scope, account: account, includesTrashAndJunk: false).prefix(limit).map(\.id)
        return try ids.compactMap { try index.summary(of: $0) }
    }

    /// One message as the list shows it.
    public func summary(of id: MailMessageID) throws -> MessageSummary? { try index.summary(of: id) }

    /// Counts an open of this message in its sender's local open history (this Mac only).
    public func recordOpen(of id: MailMessageID, at date: Date = Date()) throws {
        guard let verdict = try index.verdict(of: id) else { return }
        let scope: SenderScope
        if let list = verdict.listID {
            let organisation = verdict.fromAddress.flatMap(DomainCheck.domain(ofAddress:)).map(DomainCheck.organisationDomain(of:))
            scope = .list(id: list, organisation: organisation)
        } else if let address = verdict.fromAddress {
            scope = .sender(address)
        } else {
            return
        }
        var history = try openHistory()
        let key = SenderSummary.key(account: verdict.account, scope: scope)
        var record = history.senders[key] ?? SenderOpenRecord(opens: 0, lastOpened: date)
        record.opens += 1
        record.lastOpened = date
        history.senders[key] = record
        try writer.write(JSONCoding.prettyEncoder.encode(history), to: SenderOpenHistory.url(in: locations.deviceFolder))
        classification.openHistory = history
    }

    /// The newest message of a sender or list and its list headers, read from the stored file.
    public func listHeaders(of scope: SenderScope, account: MailAccountID) throws -> SenderListHeaders? {
        guard let newest = try index.members(of: scope, account: account).first else { return nil }
        let parsed = try parser.parse(Data(contentsOf: url(of: newest.id)))
        var headers: [String: String] = [:]
        for name in ["List-Unsubscribe", "List-Unsubscribe-Post", "List-ID", "List-Post"] {
            if let value = parsed.headers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                headers[name] = value
            }
        }
        return SenderListHeaders(message: newest.id, account: account, verdict: try index.verdict(of: newest.id),
                                 headers: headers, recipients: parsed.to + parsed.cc)
    }

    // MARK: Rules

    /// Your sender and list rules, in order: the first that matches a message wins.
    public func senderRules() throws -> [SenderRule] { try senderRuleSet().rules }

    /// What `rules` would do, without saving anything: every message a changed rule could
    /// touch, where it is now and where it would be.
    public func previewSenderRules(_ rules: [SenderRule]) throws -> SenderRulePreview {
        let current = try senderRules()
        var items: [SenderRulePreview.Item] = []
        for (id, account) in try affected(by: current, and: rules) {
            let parsed = try parser.parse(Data(contentsOf: url(of: id)))
            let planned = try plan(id, account: account, parsed: parsed, rules: rules)
            items.append(try previewItem(id, planned: planned, rules: rules, before: try index.verdict(of: id)))
        }
        return SenderRulePreview(items: items.sorted { ($0.date, $0.id) > ($1.date, $1.id) })
    }

    /// Saves `rules` (your whole ordered list) and classifies again every message a changed rule
    /// could touch. Returns the rules as they were, for Undo, and what changed: the same items a
    /// preview of `rules` listed, now read back from the index.
    @discardableResult
    public func setSenderRules(_ rules: [SenderRule]) throws -> (previous: [SenderRule], result: SenderRulePreview) {
        let previous = try senderRules()
        let affected = try affected(by: previous, and: rules)
        var before: [MailMessageID: StoredVerdict] = [:]
        for (id, _) in affected { before[id] = try index.verdict(of: id) }
        let stamped = rules.map { rule in
            var rule = rule
            if let old = previous.first(where: { $0.id == rule.id }), old != rule { rule.updatedAt = Date() }
            return rule
        }
        try senderRuleSet(SenderRuleSet(rules: stamped))
        var items: [SenderRulePreview.Item] = []
        try index.batch {
            for (id, account) in affected { try reclassify(id, account: account) }
        }
        for (id, account) in affected {
            let parsed = try parser.parse(Data(contentsOf: url(of: id)))
            let planned = try plan(id, account: account, parsed: parsed, rules: stamped)
            var item = try previewItem(id, planned: planned, rules: stamped, before: before[id])
            // What the index holds now, not what the plan says: the two are compared in tests.
            if let saved = try index.verdict(of: id) { item.after = Self.placement(saved) }
            items.append(item)
        }
        return (previous, SenderRulePreview(items: items.sorted { ($0.date, $0.id) > ($1.date, $1.id) }))
    }

    /// Which rule decided this message, why, and which others also matched.
    public func explainSenderRule(for id: MailMessageID) throws -> SenderRuleExplanation? {
        guard let account = try index.account(of: id) else { return nil }
        let rules = try senderRules()
        let parsed = try parser.parse(Data(contentsOf: url(of: id)))
        let planned = try plan(id, account: account, parsed: parsed, rules: rules)
        guard let winner = planned.winner, let effect = planned.effect,
              let position = rules.firstIndex(where: { $0.id == winner.id }) else { return nil }
        return SenderRuleExplanation(winner: winner, position: position + 1, effect: effect, alsoMatched: planned.alsoMatched)
    }

    /// Messages the rule decided and put out of Focused, for archiving at the provider.
    public func messagesSilenced(by rule: String) throws -> [MailMessageID] {
        try index.messages(decidedBy: rule).map(\.id).filter { try index.verdict(of: $0)?.isSilenced == true }
    }

    // MARK: Planning (shared with classification)

    /// The verdict for one message with these sender rules: the rule that matches first in your
    /// order wins; a category rule goes to the classifier (never lowering risk); a correction of
    /// the message still wins over both.
    func plan(_ id: MailMessageID, account: MailAccountID, parsed: ParsedMessage, rules: [SenderRule]) throws -> PlannedVerdict {
        var context = try classificationContext(account)
        var input = Self.classificationInput(parsed, folders: try index.mailboxes(of: id))
        let fingerprint = ContentFingerprint.of(parsed)
        let from = parsed.from.first?.address.lowercased()
        let fromDomain = from.flatMap(DomainCheck.domain(ofAddress:)).map(DomainCheck.organisationDomain(of:))
        let listID = input.value("List-ID").map(Self.listIdentity)
        let facts = SenderFacts(account: account, address: from, listID: listID, organisation: fromDomain, fingerprint: fingerprint)
        let matched = SenderRuleEngine.matching(rules, facts)
        let winner = matched.first
        if let winner, case .category(let purpose) = winner.action {
            let scope: ScopedRule.Scope = winner.scope.listID != nil ? .listID(listID ?? "") : .senderAddress(from ?? "")
            context.rules = [ScopedRule(id: winner.id, scope: scope, purpose: purpose)]
        }
        if let correction = try metadata().correction(account: account, messageID: parsed.messageID, fingerprint: fingerprint) {
            // The classifier matches overrides by message id; the correction's own id stands in,
            // so a message without a Message-ID can be corrected too.
            let key = "gkm-correction:" + correction.id
            input.messageID = key
            context.overrides = [MessageOverride(messageID: key, purpose: correction.purpose, risk: correction.risk)]
        }
        let verdict = MailClassifier(context: context).classify(input)
        var effect: SenderRuleEffect?
        if let winner {
            let corrected = verdict.reasons.contains(.userOverride)
            let latest = winner.action == .keepLatestOnly ? try isLatest(id, fingerprint: fingerprint, of: winner) : false
            effect = SenderRuleEngine.effect(of: winner, classification: verdict, isCorrected: corrected, isLatest: latest)
        }
        let disposition: SenderDisposition? = if case .disposition(let value) = effect { value } else { nil }
        let user: Set<ReasonCode> = [.userOverride, .userRuleList, .userRuleSender, .userRuleDomain]
        let stored = StoredVerdict(id: id, account: account, classification: verdict,
                                   home: SenderRuleEngine.home(classifierHome: verdict.home, effect: effect),
                                   isCorrected: !user.isDisjoint(with: verdict.reasons) || disposition != nil,
                                   fromAddress: from, listID: listID, senderRule: winner?.id, disposition: disposition)
        return PlannedVerdict(stored: stored, fromDomain: fromDomain, fingerprint: fingerprint, winner: winner, effect: effect,
                              alsoMatched: Array(matched.dropFirst()))
    }

    /// True when the message is the newest one the rule matches (keep latest only).
    private func isLatest(_ id: MailMessageID, fingerprint: String, of rule: SenderRule) throws -> Bool {
        guard let mine = try index.dateAndFingerprint(of: id) else { return true }
        let newestOther = try index.members(of: rule.scope, account: rule.account)
            .first { $0.id != id && !rule.excluded.contains($0.fingerprint) }
        guard let newestOther else { return true }
        return (mine.date, id.rawValue) > (newestOther.date, newestOther.id.rawValue)
    }

    /// After a message was classified: when it became the newest of a keep-latest rule, the
    /// message that was newest before is classified again (it is muted now).
    func refreshLatest(after planned: PlannedVerdict) throws {
        guard let rule = planned.winner, rule.action == .keepLatestOnly, planned.effect == .protected(.latest) else { return }
        for member in try index.members(of: rule.scope, account: rule.account) where member.id != planned.stored.id {
            guard let verdict = try index.verdict(of: member.id), verdict.senderRule == rule.id, verdict.disposition == nil else { continue }
            try reclassify(member.id, account: rule.account)
        }
    }

    /// Messages whose verdict a change from `old` to `new` rules can change: those in the scope of
    /// a rule that was added, removed, edited or moved.
    private func affected(by old: [SenderRule], and new: [SenderRule]) throws -> [(MailMessageID, MailAccountID)] {
        var scopes: [(SenderScope, MailAccountID)] = []
        let oldByID = Dictionary(old.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { a, _ in a })
        let newByID = Dictionary(new.enumerated().map { ($1.id, ($0, $1)) }, uniquingKeysWith: { a, _ in a })
        for id in Set(oldByID.keys).union(newByID.keys) {
            let before = oldByID[id], after = newByID[id]
            if let before, let after, before.0 == after.0, before.1 == after.1 { continue }
            if let before { scopes.append((before.1.scope, before.1.account)) }
            if let after { scopes.append((after.1.scope, after.1.account)) }
        }
        var seen = Set<MailMessageID>()
        var result: [(MailMessageID, MailAccountID)] = []
        for (scope, account) in scopes {
            for member in try index.members(of: scope, account: account) where seen.insert(member.id).inserted {
                result.append((member.id, account))
            }
        }
        return result
    }

    private func previewItem(_ id: MailMessageID, planned: PlannedVerdict, rules: [SenderRule],
                             before: StoredVerdict?) throws -> SenderRulePreview.Item {
        let summary = try index.summary(of: id)
        let protection: SenderRuleProtection? = if case .protected(let reason) = planned.effect { reason } else { nil }
        let excluded = rules.contains { rule in
            rule.excluded.contains(planned.fingerprint) && rule.account == planned.stored.account
                && rule.scope.matches(address: planned.stored.fromAddress, listID: planned.stored.listID, organisation: planned.fromDomain)
        }
        return SenderRulePreview.Item(id: id, account: planned.stored.account, subject: summary?.subject, from: summary?.from,
                                      date: summary?.date ?? Date(timeIntervalSince1970: 0), fingerprint: planned.fingerprint,
                                      before: before.map(Self.placement), after: Self.placement(planned.stored),
                                      protection: protection, isExcluded: excluded)
    }

    static func placement(_ verdict: StoredVerdict) -> SenderPlacement {
        SenderPlacement(home: verdict.home, purpose: verdict.classification.purpose, disposition: verdict.disposition, rule: verdict.senderRule)
    }

    // MARK: Files

    func senderRuleSet() throws -> SenderRuleSet {
        if let set = classification.senderRules { return set }
        let set = try SenderRuleSet.load(from: SenderRuleSet.url(in: locations.deviceFolder))
        classification.senderRules = set
        return set
    }

    private func senderRuleSet(_ set: SenderRuleSet) throws {
        try set.save(to: SenderRuleSet.url(in: locations.deviceFolder), writer: writer)
        classification.senderRules = set
    }

    private func openHistory() throws -> SenderOpenHistory {
        if let history = classification.openHistory { return history }
        let url = SenderOpenHistory.url(in: locations.deviceFolder)
        let history = FileManager.default.fileExists(atPath: url.path)
            ? try JSONCoding.decoder.decode(SenderOpenHistory.self, from: Data(contentsOf: url))
            : SenderOpenHistory()
        classification.openHistory = history
        return history
    }
}
