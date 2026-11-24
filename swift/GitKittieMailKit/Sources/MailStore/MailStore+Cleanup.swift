import Foundation
import MailClassifier
import MailCore

// The cleanup dashboard (GKM-021; Cleanup.swift has the types, MAIL-058..061 the decisions).
//
// The analysis and the preview only read: the index, this device's sync state and the journal's
// open rows. `runCleanup` is the one write, and it is a single step of this actor: it computes
// the preview again from the latest state, compares it with the one you confirmed message by
// message, and only when every message is exactly as previewed writes the journal rows — so no
// sync pass can land between the check and the write.

extension MailStore {
    /// Below this confidence a verdict is uncertain, unless you decided it.
    static let cleanupConfidence = 0.7
    /// Samples per group.
    static let cleanupSamples = 5
    /// Noisy senders and lists listed.
    static let noisyLimit = 30

    // MARK: - The dashboard

    /// What clutters the mailbox: composition per account, noisy senders and lists, ended
    /// offers, recurring digests and large messages. Reads only.
    public func cleanupOverview(options: CleanupOptions = CleanupOptions(), now: Date = Date()) throws -> CleanupOverview {
        let accounts = try accounts().map(\.id)
        let totals = try index.messageCounts()
        let known = Set(accounts)
        let ids = accounts + totals.keys.filter { !known.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        var composition: [CleanupComposition] = []
        for account in ids where (totals[account] ?? 0) > 0 {
            composition.append(CleanupComposition(account: account, total: totals[account] ?? 0,
                                                  categories: try index.categoryCounts(account: account)))
        }

        var noisy: [CleanupGroup] = []
        for stream in try index.noisyStreams(minimum: options.noisyMinimum, limit: Self.noisyLimit) {
            let kind: CleanupGroupID.Kind
            if let list = stream.list { kind = .list(list) } else if let sender = stream.sender { kind = .sender(sender) } else { continue }
            let id = CleanupGroupID(account: stream.account, kind: kind)
            if let group = Self.group(id, rows: try members(of: id, options: options, now: now).map(\.row)) { noisy.append(group) }
        }

        var offers: [CleanupGroup] = []
        var digests: [CleanupGroup] = []
        var large: [CleanupGroup] = []
        for account in ids where (totals[account] ?? 0) > 0 {
            let offerID = CleanupGroupID(account: account, kind: .expiredOffers)
            if let group = Self.group(offerID, rows: try members(of: offerID, options: options, now: now).map(\.row)) { offers.append(group) }
            for series in try digestSeries(account: account) {
                if let group = Self.group(series.id, rows: Array(series.rows.dropFirst())) { digests.append(group) }
            }
            let largeID = CleanupGroupID(account: account, kind: .largeMessages)
            if let group = Self.group(largeID, rows: try members(of: largeID, options: options, now: now).map(\.row)) { large.append(group) }
        }
        noisy.sort { ($0.count, $1.title) > ($1.count, $0.title) }
        digests.sort { ($0.count, $1.title) > ($1.count, $0.title) }

        return CleanupOverview(composition: composition, noisy: noisy, expiredOffers: offers, digests: digests, largeMessages: large,
                               unclassified: try index.unclassifiedCount(ruleSetVersion: MailClassifier.ruleSetVersion), analysedAt: now)
    }

    /// One group as it is now, or nil when it has no messages left.
    public func cleanupGroup(_ id: CleanupGroupID, options: CleanupOptions = CleanupOptions(), now: Date = Date()) throws -> CleanupGroup? {
        Self.group(id, rows: try members(of: id, options: options, now: now).map(\.row))
    }

    // MARK: - Preview

    /// The exact scope of `operation` on the group: every message it would change, with the
    /// journal changes it would make, and every message of the group it leaves alone and why.
    public func previewCleanup(_ group: CleanupGroupID, operation: CleanupOperation, options: CleanupOptions = CleanupOptions(),
                               now: Date = Date()) throws -> CleanupPreview {
        let context = try cleanupContext(account: group.account)
        var included: [CleanupItem] = []
        var protected: [CleanupItem] = []
        var skipped: [CleanupItem] = []
        for member in try members(of: group, options: options, now: now) {
            let item = try evaluate(member, operation: operation, options: options, now: now, context: context)
            if !item.protections.isEmpty {
                protected.append(item)
            } else if item.skip != nil || item.changes.isEmpty {
                skipped.append(item)
            } else {
                included.append(item)
            }
        }
        return CleanupPreview(id: UUID().uuidString, group: group, operation: operation, options: options, included: included,
                              protected: protected, skipped: skipped, createdAt: now)
    }

    // MARK: - Running

    /// Runs a preview you confirmed, minus the messages you excluded, as one journal batch.
    ///
    /// First the preview is made again from the latest state (provider folders and flags as
    /// synced, open journal rows, verdicts, your rules and corrections, spaces). Every message
    /// to run must still be in the group, unprotected, in the same folders with the same flags,
    /// and get the same changes; otherwise nothing runs and the differences are thrown. Messages
    /// that joined the group since the preview are not run: you have not seen them.
    @discardableResult
    public func runCleanup(_ preview: CleanupPreview, excluding excluded: Set<MailMessageID> = [], now: Date = Date()) throws -> CleanupRun {
        let chosen = preview.included.filter { !excluded.contains($0.id) }
        guard !chosen.isEmpty else { throw CleanupError.nothingToRun }

        let fresh = try previewCleanup(preview.group, operation: preview.operation, options: preview.options, now: now)
        var current: [MailMessageID: CleanupItem] = [:]
        for item in fresh.included + fresh.protected + fresh.skipped { current[item.id] = item }
        var differences: [CleanupDifference] = []
        for item in chosen {
            let change: CleanupDifference.Change?
            if let now = current[item.id] {
                if !now.protections.isEmpty {
                    change = .nowProtected(now.protections)
                } else if let skip = now.skip {
                    change = .nowSkipped(skip)
                } else if now.state != item.state || now.changes != item.changes {
                    change = .stateChanged
                } else {
                    change = nil
                }
            } else {
                change = try index.account(of: item.id) == nil ? .missing : .leftGroup
            }
            if let change { differences.append(CleanupDifference(message: item.id, subject: item.summary.subject, change: change)) }
        }
        guard differences.isEmpty else { throw CleanupError.previewChanged(differences) }

        let changes = chosen.flatMap(\.changes)
        guard let batch = try perform(changes, now: now) else { throw CleanupError.incomplete(expected: chosen.count, applied: 0) }
        guard batch.count == chosen.count else {
            try undo(batch, now: now)
            throw CleanupError.incomplete(expected: chosen.count, applied: batch.count)
        }
        return CleanupRun(batch: batch, messages: chosen.map(\.id))
    }

    // MARK: - Category rules

    /// What "Always list under Promotions/Subscriptions" would do for a sender or list: the
    /// classifier rule it makes (MAIL-039, `addRule`; no new rule type) and exactly the messages
    /// whose category it changes. A rule changes nothing at the provider (MAIL-007); your
    /// corrections of a purpose still win and Quarantine stays Quarantine, so those are not listed.
    public func previewCategoryRule(_ group: CleanupGroupID, purpose: MailPurpose) throws -> CategoryRulePreview {
        guard purpose == .promotion || purpose == .subscription else { throw CleanupError.unsupportedRule }
        let scope: ClassificationRule.Scope
        let members: [(id: MailMessageID, account: MailAccountID)]
        switch group.kind {
        case .sender(let address):
            scope = .sender(address)
            members = try index.messages(fromAddresses: [address], account: group.account)
        case .list(let list):
            scope = .list(list)
            members = try index.messages(inList: list, account: group.account)
        default:
            throw CleanupError.unsupportedRule
        }
        var affected: [MailMessageID] = []
        for member in members {
            guard let verdict = try index.verdict(of: member.id) else { continue }
            let c = verdict.classification
            guard c.purpose != purpose, !c.risk.isQuarantined else { continue }
            // Your correction of the purpose beats a rule; one of the risk only does not.
            if c.reasons.contains(.userOverride), try correction(of: member.id)?.purpose != nil { continue }
            affected.append(member.id)
        }
        let summaries = try index.summaries(ids: affected).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        let replaces = try classificationRules().last { $0.account == group.account && $0.scope == scope }
        return CategoryRulePreview(group: group, scope: scope, purpose: purpose, affected: summaries, replaces: replaces)
    }

    // MARK: - Groups

    struct CleanupMember {
        var row: CleanupRow
        var note: String?
    }

    /// The group's messages, newest first. Both the dashboard's counts and the preview come
    /// from here, so they agree.
    func members(of group: CleanupGroupID, options: CleanupOptions, now: Date) throws -> [CleanupMember] {
        let account = SQLiteValue.text(group.account.rawValue)
        switch group.kind {
        case .sender(let address):
            return try index.cleanupRows(where: "m.account_id = ? AND c.from_address = ? AND c.list_id IS NULL", [account, .text(address)])
                .map { CleanupMember(row: $0) }
        case .list(let list):
            return try index.cleanupRows(where: "m.account_id = ? AND c.list_id = ?", [account, .text(list)]).map { CleanupMember(row: $0) }
        case .expiredOffers:
            let cutoff = Self.days(-options.offerAgeDays, from: now)
            return try index.cleanupRows(where: "m.account_id = ? AND c.purpose = 'promotion' AND c.home = 'promotions'", [account])
                .compactMap { row in
                    if let end = OfferExpiry.endDate(subject: row.summary.subject, text: row.summary.snippet, sent: row.summary.date) {
                        guard end < now else { return nil }
                        return CleanupMember(row: row, note: "Offer ended \(end.formatted(date: .abbreviated, time: .omitted))")
                    }
                    guard row.summary.date < cutoff else { return nil }
                    return CleanupMember(row: row, note: "Offer older than \(options.offerAgeDays) days")
                }
        case .digest(let stream, let pattern):
            guard let series = try digestSeries(account: group.account).first(where: { $0.id.kind == .digest(stream: stream, pattern: pattern) }),
                  let newest = series.rows.first else { return [] }
            let kept = "Newer issue kept (\(newest.summary.date.formatted(date: .abbreviated, time: .omitted)))"
            return series.rows.dropFirst().map { CleanupMember(row: $0, note: kept) }
        case .largeMessages:
            return try index.cleanupRows(where: """
                m.account_id = ? AND (SELECT COALESCE(sum(b.size), 0) FROM message_blobs b WHERE b.local_id = m.local_id) >= ?
                """, [account, .int(options.largeMessageBytes)])
                .map { CleanupMember(row: $0, note: ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)) }
        }
    }

    /// Recurring digests in Updates and Subscriptions: three or more messages from one stream
    /// whose subjects match once numbers and dates are taken out. Rows newest first.
    func digestSeries(account: MailAccountID) throws -> [(id: CleanupGroupID, rows: [CleanupRow])] {
        let rows = try index.cleanupRows(where: "m.account_id = ? AND c.home IN ('subscriptions', 'updates')", [.text(account.rawValue)])
        var order: [String] = []
        var series: [String: (stream: String, pattern: String, rows: [CleanupRow])] = [:]
        for row in rows {
            guard let stream = row.listID.map({ "l:" + $0 }) ?? row.sender.map({ "s:" + $0 }),
                  let pattern = DigestPattern.of(row.summary.subject) else { continue }
            let key = stream + "\n" + pattern
            if series[key] == nil { order.append(key); series[key] = (stream, pattern, []) }
            series[key]?.rows.append(row)
        }
        return order.compactMap { key in
            guard let entry = series[key], entry.rows.count >= 3 else { return nil }
            return (CleanupGroupID(account: account, kind: .digest(stream: entry.stream, pattern: entry.pattern)), entry.rows)
        }
    }

    static func group(_ id: CleanupGroupID, rows: [CleanupRow]) -> CleanupGroup? {
        guard let newest = rows.first else { return nil }
        var homes: [MailCategory: Int] = [:]
        for row in rows { homes[row.home, default: 0] += 1 }
        let category = homes.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key
        let title: String
        var detail: String?
        switch id.kind {
        case .sender(let address):
            title = newest.summary.from?.name.flatMap { $0.isEmpty ? nil : $0 } ?? address
            detail = address
        case .list(let list):
            title = newest.summary.from?.name.flatMap { $0.isEmpty ? nil : $0 } ?? list
            detail = list
        case .expiredOffers:
            title = "Offers that have ended"
        case .digest:
            title = newest.summary.subject ?? "(No subject)"
            detail = newest.summary.from?.name ?? newest.summary.from?.address
        case .largeMessages:
            title = "Large attachments"
        }
        return CleanupGroup(id: id, title: title, detail: detail, count: rows.count, unread: rows.filter(\.summary.isUnread).count,
                            lastSeen: newest.summary.date, bytes: rows.reduce(0) { $0 + $1.bytes }, category: category,
                            samples: Array(rows.prefix(Self.cleanupSamples).map(\.summary)))
    }

    // MARK: - One message

    /// What this device knows about an account for a preview: its folder roles and your addresses.
    struct CleanupContext {
        var mapping: RemoteMapping
        var inbox: String?
        /// All Mail and Trash: Trash never takes a message out of these (MAIL-036).
        var allAndTrash: Set<String>
        var all: Set<String>
        var sent: Set<String>
        var ownAddresses: Set<String>
    }

    func cleanupContext(account: MailAccountID) throws -> CleanupContext {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let folders = try mapping.folders()
        return CleanupContext(mapping: mapping, inbox: folders.first { $0.role == "inbox" }?.name,
                              allAndTrash: Set(folders.filter { $0.role == "all" || $0.role == "trash" }.map(\.name)),
                              all: Set(folders.filter { $0.role == "all" }.map(\.name)),
                              sent: Set(folders.filter { $0.role == "sent" }.map(\.name)),
                              ownAddresses: try accountAddresses()[account] ?? [])
    }

    private func evaluate(_ member: CleanupMember, operation: CleanupOperation, options: CleanupOptions, now: Date,
                          context: CleanupContext) throws -> CleanupItem {
        let summary = member.row.summary
        let id = summary.id
        let effective = try effectiveState(of: id, mapping: context.mapping)
        let answered = try context.mapping.syncFlags(of: [id])[id]?.answered ?? false
        let state = CleanupItem.State(mailboxes: effective.mailboxes.sorted(), flagged: effective.flags.flagged, answered: answered)
        let (changes, skip) = Self.changes(for: id, in: effective.mailboxes, operation: operation, context: context)
        let protections = try protections(of: member.row, state: state, options: options, now: now, context: context)
        return CleanupItem(summary: summary, changes: protections.isEmpty && skip == nil ? changes : [], protections: protections,
                           skip: skip, note: member.note, state: state)
    }

    /// The journal changes an operation makes for a message in these folders, mirroring the
    /// everyday actions from All Mail (the app's MailActions, MAIL-036).
    static func changes(for id: MailMessageID, in mailboxes: Set<String>, operation: CleanupOperation,
                        context: CleanupContext) -> ([MailChange], CleanupSkip?) {
        guard !mailboxes.isEmpty else { return ([], .onlyOnThisMac) }
        switch operation {
        case .archive(let target, let create):
            guard let inbox = context.inbox, inbox != target, mailboxes.contains(inbox) else {
                return ([], mailboxes.contains(target) ? .alreadyInTarget : .notInInbox)
            }
            return ([MailChange(id, .move(from: inbox, to: target, createTarget: create))], nil)
        case .trash(let target, let create):
            let sources = mailboxes.subtracting(context.allAndTrash).subtracting([target]).sorted()
            guard !sources.isEmpty else { return ([], mailboxes.contains(target) ? .alreadyInTarget : .onlyInAllMail) }
            return (sources.map { MailChange(id, .move(from: $0, to: target, createTarget: create)) }, nil)
        case .move(let target):
            guard !mailboxes.contains(target) else { return ([], .alreadyInTarget) }
            let real = mailboxes.subtracting(context.all)
            let source: String? = if let inbox = context.inbox, mailboxes.contains(inbox) { inbox } else if real.count == 1 { real.first } else { nil }
            guard let source else { return ([], real.isEmpty ? .onlyInAllMail : .severalFolders) }
            return ([MailChange(id, .move(from: source, to: target))], nil)
        }
    }

    /// Why a message must not be part of any batch (MAIL-059). Empty when nothing protects it.
    private func protections(of row: CleanupRow, state: CleanupItem.State, options: CleanupOptions, now: Date,
                             context: CleanupContext) throws -> [CleanupProtection] {
        let id = row.summary.id
        var reasons = Set<CleanupProtection>()
        if state.flagged { reasons.insert(.flagged) }
        if try index.isInSpace(id) { reasons.insert(.inSpace) }

        if let verdict = try index.verdict(of: id), verdict.classification.ruleSetVersion == MailClassifier.ruleSetVersion {
            let c = verdict.classification
            if c.risk.isQuarantined || verdict.home == .quarantine { reasons.insert(.quarantined) }
            if c.risk == .suspicious || c.purpose == .unknown || (!verdict.isCorrected && c.confidence < Self.cleanupConfidence) {
                reasons.insert(.uncertain)
            }
            if verdict.home == .focused || c.purpose == .conversation || c.purpose == .security { reasons.insert(.important) }
            if c.purpose == .transaction && !options.includeTransactions { reasons.insert(.transaction) }
        } else {
            // Not sorted yet, or sorted by an older rule set that is being replaced.
            reasons.insert(.uncertain)
        }

        let thread = try index.thread(row.summary.threadID)
        let recent = Self.days(-options.recentDays, from: now)
        if thread.contains(where: { $0.date >= recent }) || row.summary.date >= recent { reasons.insert(.recent) }
        if try thread.contains(where: { try isYours($0, context: context) }) { reasons.insert(.repliedByYou) }
        return CleanupProtection.allCases.filter(reasons.contains)
    }

    /// You wrote it (your address, or it is in Sent), or it is marked answered at the provider.
    private func isYours(_ message: MessageSummary, context: CleanupContext) throws -> Bool {
        if let from = message.from?.address.lowercased(), context.ownAddresses.contains(from) { return true }
        if !context.sent.isEmpty, try !Set(index.mailboxes(of: message.id)).isDisjoint(with: context.sent) { return true }
        return try context.mapping.syncFlags(of: [message.id])[message.id]?.answered ?? false
    }

    static func days(_ count: Int, from date: Date) -> Date { date.addingTimeInterval(TimeInterval(count) * 24 * 3600) }
}

/// A digest's subject with what changes per issue taken out: numbers, month and weekday names.
/// "Your weekly summary for Nov 17" and "… for Nov 24" give the same pattern. Nil when too
/// little is left to tell series apart.
enum DigestPattern {
    private static let variable: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may", "jun", "june", "jul", "july", "aug", "august",
        "sep", "sept", "september", "oct", "october", "nov", "november", "dec", "december", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "st", "nd", "rd", "th",
    ]

    static func of(_ subject: String?) -> String? {
        guard let subject else { return nil }
        let words = subject.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty && !variable.contains($0) }
        guard words.joined().count >= 6, words.count >= 2 else { return nil }
        return words.joined(separator: " ")
    }
}
