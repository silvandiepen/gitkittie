import Foundation
import MailClassifier
import MailCore

// Classification in the store (GKM-017; MAIL-038, MAIL-039). Every message is classified when
// it is stored, read-only: the verdict goes into the index, nothing is written to the mail
// folder, the `.eml`, the sync state or the provider (MAIL-007). Messages stored before (an older
// index, a rebuild, a new rule set) are classified by `classifyPending`, which the app runs in the
// background; until then they count as Focused, so nothing is hidden.

/// Which `Authentication-Results` servers the store believes, per account (ThreatModel §3).
public struct ClassificationOptions: Sendable {
    /// `authserv-id`s to trust for an account in addition to `VerifiedAuthServers`. For a
    /// provider whose behaviour has been verified; never filled from the message itself.
    public var trustedAuthServIDs: [MailAccountID: Set<String>]

    public init(trustedAuthServIDs: [MailAccountID: Set<String>] = [:]) {
        self.trustedAuthServIDs = trustedAuthServIDs
    }
}

/// Providers whose `Authentication-Results` we have verified: that they add the header under
/// this `authserv-id` and remove any copy that arrives from outside. None yet: the GKM-004 run
/// records what iCloud does; Gmail's is checked with GKM-029. Until then authentication is
/// "no evidence", never "pass", and the trusted-sender list stays empty in the app.
public enum VerifiedAuthServers {
    public static func ids(for kind: MailAccountKind?) -> Set<String> {
        switch kind {
        case .iCloud, .gmail, .imap, nil: []
        }
    }
}

/// What the store remembers between classifications.
struct ClassificationState {
    var options = ClassificationOptions()
    var metadata: ClassificationMetadata?
    /// Per account, without corrections (those are per message).
    var contexts: [MailAccountID: ClassificationContext] = [:]
    var accountAddresses: [MailAccountID: Set<String>]?
    /// Your sender and list rules (GKM-019), and this device's open history per sender.
    var senderRules: SenderRuleSet?
    var openHistory: SenderOpenHistory?
    /// The last classification that failed after its message was stored safely; the message
    /// stays unclassified (Focused) and `classifyPending` tries it again.
    var lastError: String?
}

extension MailStore {
    /// How long a domain must have passed trusted authentication, and on how many messages,
    /// before its lookalikes count as impersonation; or you have written to someone there.
    static let establishedRelationship: (messages: Int, span: TimeInterval) = (2, 7 * 24 * 3600)

    // MARK: Reading

    /// The stored verdict of a message; nil until it has been classified.
    public func verdict(of id: MailMessageID) throws -> StoredVerdict? {
        try index.verdict(of: id)
    }

    /// Messages and unread messages per category view (GKM-018), for one account or all.
    public func categoryCounts(account: MailAccountID? = nil) throws -> [MailCategory: CategoryCount] {
        try index.categoryCounts(account: account)
    }

    /// Messages still to classify with the current rule set.
    public func pendingClassificationCount() throws -> Int {
        try index.unclassifiedCount(ruleSetVersion: MailClassifier.ruleSetVersion)
    }

    /// The newest arrival number; the app starts notifying after it.
    public func latestArrival() throws -> Int64 { try index.latestArrival() }

    /// Messages that arrived (were stored and classified) after `sequence`, oldest first.
    public func arrivals(after sequence: Int64, limit: Int = 200) throws -> [MailArrival] {
        try index.arrivals(after: sequence, limit: limit)
    }

    /// Why the last classification after storing a message failed, if it did.
    public var lastClassificationError: String? { classification.lastError }

    // MARK: Classifying

    /// Classifies up to `limit` messages that have no verdict from the current rule set: after
    /// an index rebuild, an upgrade from an index without verdicts, or a new rule set. Your
    /// corrections and rules apply as always. Returns how many it classified; 0 means done.
    @discardableResult
    public func classifyPending(limit: Int = 200) throws -> Int {
        let pending = try index.unclassified(ruleSetVersion: MailClassifier.ruleSetVersion, limit: limit)
        for (id, account) in pending { try reclassify(id, account: account) }
        return pending.count
    }

    /// Called by `ingest` once the message is durable. A failure here never undoes the stored
    /// message: it is recorded, and the message waits for `classifyPending`.
    func classifyAfterIngest(_ id: MailMessageID, account: MailAccountID, parsed: ParsedMessage) {
        do {
            try classify(id, account: account, parsed: parsed, arrival: true)
            classification.lastError = nil
        } catch {
            classification.lastError = String(describing: error)
        }
    }

    /// Classifies a stored message again (its folders changed, a correction or rule changed).
    /// A message that was never classified is left to `classifyPending`.
    func reclassifyIfClassified(_ id: MailMessageID) {
        do {
            guard let verdict = try index.verdict(of: id) else { return }
            try reclassify(id, account: verdict.account)
        } catch {
            classification.lastError = String(describing: error)
        }
    }

    func reclassify(_ id: MailMessageID, account: MailAccountID) throws {
        let parsed = try parser.parse(Data(contentsOf: url(of: id)))
        try classify(id, account: account, parsed: parsed, arrival: false)
    }

    /// The verdict comes from `plan` (MailStore+Senders.swift): the classifier with your
    /// corrections, correction-made rules and sender rules, exactly as a rule preview runs it.
    private func classify(_ id: MailMessageID, account: MailAccountID, parsed: ParsedMessage, arrival: Bool) throws {
        let planned = try plan(id, account: account, parsed: parsed, rules: senderRules())
        try index.saveVerdict(planned.stored, fromDomain: planned.fromDomain, arrival: arrival)
        try refreshLatest(after: planned)
        try learn(from: parsed, verdict: planned.stored.classification, id: id, account: account, fromDomain: planned.fromDomain)
    }

    /// What one message teaches about the mailbox: whom you write to, and which domains pass
    /// trusted authentication. When that changes a past verdict, the affected messages are
    /// classified again (only those: senders you now know, lookalikes of a newly trusted domain;
    /// a link to a lookalike in older mail is caught when that mail is next classified).
    private func learn(from parsed: ParsedMessage, verdict: Classification, id: MailMessageID, account: MailAccountID,
                       fromDomain: String?) throws {
        let own = try accountAddresses()[account] ?? []
        let sentByYou = parsed.from.first.map { own.contains($0.address.lowercased()) } ?? false
        // A bare public suffix (an address directly at a reserved example domain) is no organisation.
        let authenticated = verdict.reasons.contains(.authTrustedPass) && verdict.risk == .none
            && fromDomain.map { !DomainCheck.isPublicSuffix($0) } == true
        guard sentByYou || authenticated else { return }
        let trustedBefore = try trustedSenderDomains()
        var newCorrespondents = Set<String>()
        if sentByYou {
            newCorrespondents = try index.addCorrespondents(Set((parsed.to + parsed.cc).map { $0.address.lowercased() }).subtracting(own))
        }
        if authenticated, let fromDomain { try index.recordAuthenticatedDomain(fromDomain, at: parsed.date ?? Date()) }
        let newlyTrusted = try trustedSenderDomains().subtracting(trustedBefore)
        guard !newCorrespondents.isEmpty || !newlyTrusted.isEmpty else { return }
        classification.contexts = [:]
        var affected = try index.messages(fromAddresses: newCorrespondents, account: nil)
        if !newlyTrusted.isEmpty {
            let lookalikes = try index.senderDomains().filter { DomainCheck.lookalikeTarget(ofHost: $0, trusted: newlyTrusted) != nil }
            affected += try index.messages(fromDomains: lookalikes)
        }
        var done = Set([id])
        for (other, otherAccount) in affected where done.insert(other).inserted {
            try reclassify(other, account: otherAccount)
        }
    }

    // MARK: Corrections and rules

    /// Your correction of one message: a purpose ("Move to Transactions"), a risk ("Not
    /// phishing" is `.none`), or both. Applied at once and kept through rule-set upgrades and
    /// index rebuilds. It never generalises; `addRule` is the explicit way to do that.
    @discardableResult
    public func correct(_ id: MailMessageID, purpose: MailPurpose? = nil, risk: MailRisk? = nil) throws -> StoredVerdict? {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        let parsed = try parser.parse(Data(contentsOf: url(of: id)))
        let fingerprint = ContentFingerprint.of(parsed)
        var metadata = try metadata()
        let now = Date()
        if let index = metadata.corrections.lastIndex(where: { $0.account == account && $0.fingerprint == fingerprint }) {
            if let purpose { metadata.corrections[index].purpose = purpose }
            if let risk { metadata.corrections[index].risk = risk }
            metadata.corrections[index].updatedAt = now
        } else {
            metadata.corrections.append(ClassificationCorrection(id: UUID().uuidString.lowercased(), account: account,
                                                                 messageID: parsed.messageID, fingerprint: fingerprint, purpose: purpose,
                                                                 risk: risk, createdAt: now, updatedAt: now))
        }
        try save(metadata)
        try reclassifyMatching(account: account, messageID: parsed.messageID, fingerprint: fingerprint, also: id)
        return try index.verdict(of: id)
    }

    /// Your correction of this message, if any.
    public func correction(of id: MailMessageID) throws -> ClassificationCorrection? {
        guard let account = try index.account(of: id) else { return nil }
        let parsed = try parser.parse(Data(contentsOf: url(of: id)))
        return try metadata().correction(account: account, messageID: parsed.messageID, fingerprint: ContentFingerprint.of(parsed))
    }

    /// Takes back your correction of a message; the classifier decides again.
    @discardableResult
    public func removeCorrection(of id: MailMessageID) throws -> StoredVerdict? {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        let parsed = try parser.parse(Data(contentsOf: url(of: id)))
        let fingerprint = ContentFingerprint.of(parsed)
        var metadata = try metadata()
        metadata.corrections.removeAll { $0.matches(account: account, messageID: parsed.messageID, fingerprint: fingerprint) }
        try save(metadata)
        try reclassifyMatching(account: account, messageID: parsed.messageID, fingerprint: fingerprint, also: id)
        return try index.verdict(of: id)
    }

    /// Your rules, newest last.
    public func classificationRules() throws -> [ClassificationRule] { try metadata().rules }

    /// Makes a rule you chose from a correction: every message from this sender, or on this
    /// list, in this account. Replaces an earlier rule for the same scope. Returns the rule.
    @discardableResult
    public func addRule(_ scope: ClassificationRule.Scope, purpose: MailPurpose, account: MailAccountID) throws -> ClassificationRule {
        let normalised: ClassificationRule.Scope = switch scope {
        case .sender(let address): .sender(address.lowercased())
        case .list(let list): .list(Self.listIdentity(list))
        }
        var metadata = try metadata()
        metadata.rules.removeAll { $0.account == account && $0.scope == normalised }
        let rule = ClassificationRule(id: UUID().uuidString.lowercased(), account: account, scope: normalised, purpose: purpose,
                                      isEnabled: true, createdAt: Date())
        metadata.rules.append(rule)
        try save(metadata)
        try reclassify(scope: normalised, account: account)
        return rule
    }

    public func removeRule(id: String) throws {
        var metadata = try metadata()
        guard let rule = metadata.rules.first(where: { $0.id == id }) else { return }
        metadata.rules.removeAll { $0.id == id }
        try save(metadata)
        try reclassify(scope: rule.scope, account: rule.account)
    }

    private func reclassify(scope: ClassificationRule.Scope, account: MailAccountID) throws {
        classification.contexts[account] = nil
        let affected = switch scope {
        case .sender(let address): try index.messages(fromAddresses: [address], account: account)
        case .list(let list): try index.messages(inList: list, account: account)
        }
        for (id, account) in affected { try reclassify(id, account: account) }
    }

    private func reclassifyMatching(account: MailAccountID, messageID: String?, fingerprint: String, also id: MailMessageID) throws {
        var ids = Set(try index.candidates(account: account, messageID: messageID, fingerprint: fingerprint))
        ids.insert(id)
        for other in ids.sorted() { try reclassify(other, account: account) }
    }

    // MARK: Context

    func metadata() throws -> ClassificationMetadata {
        if let metadata = classification.metadata { return metadata }
        let metadata = try ClassificationMetadata.load(from: ClassificationMetadata.url(in: locations.deviceFolder))
        classification.metadata = metadata
        return metadata
    }

    private func save(_ metadata: ClassificationMetadata) throws {
        try metadata.save(to: ClassificationMetadata.url(in: locations.deviceFolder), writer: writer)
        classification.metadata = metadata
        classification.contexts = [:]
    }

    private func accountAddresses() throws -> [MailAccountID: Set<String>] {
        if let known = classification.accountAddresses { return known }
        var result: [MailAccountID: Set<String>] = [:]
        for account in try accounts() where !account.address.isEmpty { result[account.id] = [account.address.lowercased()] }
        classification.accountAddresses = result
        return result
    }

    /// Forgets cached account details (an account was added or removed).
    func invalidateClassificationContext() {
        classification.contexts = [:]
        classification.accountAddresses = nil
    }

    func classificationContext(_ account: MailAccountID) throws -> ClassificationContext {
        if let context = classification.contexts[account] { return context }
        let kind = try accounts().first { $0.id == account }?.connection?.kind
        let context = ClassificationContext(
            accountAddresses: try accountAddresses()[account] ?? [],
            trustedAuthServIDs: VerifiedAuthServers.ids(for: kind).union(classification.options.trustedAuthServIDs[account] ?? []),
            knownCorrespondents: try index.correspondents(),
            trustedSenderDomains: try trustedSenderDomains(),
            rules: try metadata().scopedRules(account: account))
        classification.contexts[account] = context
        return context
    }

    /// Organisations you have an established relationship with: they passed trusted
    /// authentication on several messages over at least a week, or passed it and you have
    /// written to someone there. A domain that imitates one already trusted never becomes trusted itself, however
    /// well it authenticates (a phisher can pass DMARC for their own lookalike domain).
    func trustedSenderDomains() throws -> Set<String> {
        let correspondentDomains = Set(try index.correspondents().compactMap(DomainCheck.domain(ofAddress:)).map(DomainCheck.organisationDomain(of:)))
        let established = try index.authenticatedDomains()
            .filter { correspondentDomains.contains($0.domain)
                || ($0.messages >= Self.establishedRelationship.messages
                    && $0.lastSeen.timeIntervalSince($0.firstSeen) >= Self.establishedRelationship.span) }
            .sorted { ($0.firstSeen, $0.domain) < ($1.firstSeen, $1.domain) }
        var trusted = Set<String>()
        for candidate in established where DomainCheck.lookalikeTarget(ofHost: candidate.domain, trusted: trusted) == nil {
            trusted.insert(candidate.domain)
        }
        return trusted
    }

    // MARK: Input

    static func classificationInput(_ parsed: ParsedMessage, folders: [String]) -> ClassificationInput {
        var flags: Set<StructureFlag> = []
        if parsed.problems.contains(where: { $0.hasPrefix("nesting deeper") }) { flags.insert(.nestingLimitExceeded) }
        if parsed.hasUnsafeAttachmentNames { flags.insert(.unsafeAttachmentFilename) }
        return ClassificationInput(
            messageID: parsed.messageID, from: parsed.from.first, replyTo: parsed.replyTo, subject: parsed.subject ?? "",
            headers: parsed.headers.map { .init(name: $0.name, value: $0.value) }, textBody: parsed.textBody ?? "",
            htmlBody: parsed.htmlBody, attachmentFilenames: parsed.attachments.compactMap(\.fileName), structureFlags: flags,
            provider: folders.isEmpty ? nil : ProviderSignals(folders: folders))
    }

    /// A List-ID as rules and the index keep it: the part in angle brackets, lowercased.
    static func listIdentity(_ value: String) -> String {
        if let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            return value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }
}
