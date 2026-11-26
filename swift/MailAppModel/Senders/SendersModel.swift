import Foundation
import MailClassifier
import MailCore
import MailStore
import MailSync
import Observation

/// The Senders view (GKM-019): every sender and list, your rules for them in order, and the
/// preview you approve before a rule changes anything. UI-free; the views send intents.
///
/// Rules are virtual (MAIL-054): muting or silently archiving changes where a message shows here,
/// never its folders or flags at the provider. Only a rule you set to "also archive at your
/// provider" moves mail, and that goes through the action journal like any Archive, with Undo.
/// Always Junk and Always Trash (GKM-072, MAIL-109..111) block a sender: applying one moves its
/// mail to Junk or Trash through the journal in the same Undo as the rule, and new mail from it
/// is moved after each sync. Flagged mail and mail in a space stay where they are.
@MainActor
@Observable
final class SendersModel {
    enum Sort: String, CaseIterable, Identifiable {
        case recent, volume, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: "Last Seen"
            case .volume: "Most Mail"
            case .name: "Name"
            }
        }
    }

    /// A rule change waiting for your approval, with exactly what it would do.
    struct PendingChange: Identifiable {
        let id = UUID()
        var title: String
        var rules: [SenderRule]
        var preview: SenderRulePreview
        /// The rule being added or edited, whose exclusions the preview can change.
        var ruleID: String?
        /// What a blocking rule does at the provider, or what removing one doesn't undo.
        var notes: [String] = []
    }

    private(set) var senders: [SenderSummary] = []
    private(set) var rules: [SenderRule] = []
    var sort: Sort = .recent
    var filter = ""
    var selectedID: SenderSummary.ID?
    /// A preview to approve; set by `propose`, cleared by `apply` or `cancel`.
    var pending: PendingChange?
    /// What the last change could not do, for an alert.
    var notice: String?
    /// The unsubscribe side of this view (GKM-020).
    let unsubscribe: UnsubscribeModel

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var store: MailStore?
    @ObservationIgnored private let actions: MailActions
    @ObservationIgnored private let browser: MailBrowser
    /// Called after a rule changed where mail shows: the counts and the badge.
    @ObservationIgnored var onPlacementsChanged: (@MainActor () async -> Void)?
    /// Arrivals already looked at for rules that archive at the provider.
    @ObservationIgnored private var arrivalCursor: Int64 = 0
    /// The last provider archive started by a rule, for tests.
    @ObservationIgnored private(set) var lastProviderArchive: Task<Void, Never>?

    init(actions: MailActions, browser: MailBrowser, unsubscribe: UnsubscribeModel) {
        self.actions = actions
        self.browser = browser
        self.unsubscribe = unsubscribe
    }

    func attach(_ store: MailStore) async {
        self.store = store
        unsubscribe.attach(store)
        senders = []
        rules = []
        selectedID = nil
        do {
            // The rules, at once: new mail is checked against blocking rules after every sync,
            // and the row menus offer to stop one, before the Senders view is ever opened.
            rules = try await store.senderRules()
            arrivalCursor = try await store.latestArrival()
        } catch {
            notice = String(describing: error)
        }
    }

    var selected: SenderSummary? { senders.first { $0.id == selectedID } }

    /// The senders the list shows: filtered by name, address, list or organisation, sorted.
    var visible: [SenderSummary] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? senders : senders.filter { sender in
            [sender.name, sender.address, sender.scope.name, sender.organisation].compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
        switch sort {
        case .recent: return matching
        case .volume: return matching.sorted { ($0.messages, $0.lastSeen) > ($1.messages, $1.lastSeen) }
        case .name: return matching.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    /// The rules for one sender or list, in your order.
    func rules(for sender: SenderSummary) -> [SenderRule] {
        rules.filter { $0.account == sender.account && $0.scope == sender.scope }
    }

    /// Your Always Junk and Always Trash rules, in your order (GKM-072).
    var blockingRules: [SenderRule] { rules.filter(\.action.blocks) }

    /// The blocking rule for exactly this address in this account, if there is one.
    func blockingRule(for address: String, account: MailAccountID) -> SenderRule? {
        let scope = SenderScope.sender(address.lowercased())
        return rules.first { $0.action.blocks && $0.account == account && $0.scope == scope }
    }

    /// 1-based position of a rule in your order.
    func position(of rule: SenderRule) -> Int { (rules.firstIndex { $0.id == rule.id } ?? 0) + 1 }

    // MARK: Loading

    func refresh() async {
        guard let store else { return }
        do {
            senders = try await store.senders()
            rules = try await store.senderRules()
        } catch {
            notice = String(describing: error)
        }
        if let selectedID, !senders.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        await unsubscribe.refresh()
    }

    /// Opens in the reader count in the sender's local open history.
    func recordOpen(_ ids: [MailMessageID]) async {
        guard let store else { return }
        do {
            for id in ids { try await store.recordOpen(of: id) }
        } catch {
            notice = "The open history couldn’t be saved: \(error)"
        }
    }

    /// A sender's or list's messages, newest first.
    func messages(of sender: SenderSummary, limit: Int = 50) async -> [MessageSummary] {
        guard let store else { return [] }
        do {
            return try await store.messages(of: sender.scope, account: sender.account, limit: limit)
        } catch {
            notice = String(describing: error)
            return []
        }
    }

    // MARK: Proposing (preview first, always)

    /// A new rule for this sender or list, put first in your order (so it wins), replacing any
    /// rule you had for exactly this sender or list. Shows the preview; nothing changes yet.
    func propose(_ action: SenderRuleAction, for sender: SenderSummary, archiveAtProvider: Bool = false) async {
        let rule = SenderRule(account: sender.account, scope: sender.scope, action: action, archiveAtProvider: archiveAtProvider)
        var candidate = rules.filter { !($0.account == sender.account && $0.scope == sender.scope) }
        candidate.insert(rule, at: 0)
        await preview(candidate, title: "\(SenderRuleText.title(action)) \(sender.displayName)", ruleID: rule.id)
    }

    /// Always Junk or Always Trash for one From address in one account, from a row's menu
    /// (GKM-072): like ``propose(_:for:)``, with the rules read again first, since the Senders
    /// view may never have been opened.
    func proposeBlock(_ action: SenderRuleAction, address: MailAddress, account: MailAccountID) async {
        guard action.blocks, let store, !address.address.isEmpty else { return }
        do {
            rules = try await store.senderRules()
        } catch {
            notice = String(describing: error)
            return
        }
        let scope = SenderScope.sender(address.address.lowercased())
        let rule = SenderRule(account: account, scope: scope, action: action)
        var candidate = rules.filter { !($0.account == account && $0.scope == scope) }
        candidate.insert(rule, at: 0)
        let name = address.name.flatMap { $0.isEmpty ? nil : $0 } ?? address.address
        await preview(candidate, title: "\(SenderRuleText.title(action)) \(name)", ruleID: rule.id)
    }

    func proposeEnabled(_ enabled: Bool, rule: SenderRule) async {
        await change(rule, title: enabled ? "Turn On Rule" : "Turn Off Rule") { $0.isEnabled = enabled }
    }

    func proposeArchiveAtProvider(_ archive: Bool, rule: SenderRule) async {
        await change(rule, title: archive ? "Also Archive at Your Provider" : "Keep Mail Where It Is") {
            $0.archiveAtProvider = archive && $0.action.canArchiveAtProvider
        }
    }

    func proposeRemoval(of rule: SenderRule) async {
        await preview(rules.filter { $0.id != rule.id }, title: "Remove Rule", ruleID: nil)
    }

    /// Moves a rule up (earlier, wins more) or down in your order.
    func proposeMove(_ rule: SenderRule, by offset: Int) async {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let target = min(max(index + offset, 0), rules.count - 1)
        guard target != index else { return }
        var candidate = rules
        let moving = candidate.remove(at: index)
        candidate.insert(moving, at: target)
        await preview(candidate, title: offset < 0 ? "Move Rule Up" : "Move Rule Down", ruleID: rule.id)
    }

    /// Takes a message out of the pending rule (or puts it back); the preview updates.
    func toggleExclusion(_ item: SenderRulePreview.Item) async {
        guard var pending, let ruleID = pending.ruleID, let index = pending.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        var rule = pending.rules[index]
        if let at = rule.excluded.firstIndex(of: item.fingerprint) { rule.excluded.remove(at: at) } else { rule.excluded.append(item.fingerprint) }
        pending.rules[index] = rule
        guard let store else { return }
        do {
            pending.preview = try await store.previewSenderRules(pending.rules)
            pending.notes = SenderRuleText.blockNotes(current: rules, candidate: pending.rules, preview: pending.preview)
            self.pending = pending
        } catch {
            notice = String(describing: error)
        }
    }

    func cancel() { pending = nil }

    private func change(_ rule: SenderRule, title: String, _ edit: (inout SenderRule) -> Void) async {
        var candidate = rules
        guard let index = candidate.firstIndex(where: { $0.id == rule.id }) else { return }
        edit(&candidate[index])
        await preview(candidate, title: title, ruleID: rule.id)
    }

    private func preview(_ candidate: [SenderRule], title: String, ruleID: String?) async {
        guard let store else { return }
        do {
            let preview = try await store.previewSenderRules(candidate)
            pending = PendingChange(title: title, rules: candidate, preview: preview, ruleID: ruleID,
                                    notes: SenderRuleText.blockNotes(current: rules, candidate: candidate, preview: preview))
        } catch {
            notice = String(describing: error)
        }
    }

    // MARK: Applying

    /// Applies the approved change: exactly the previewed rules. Returns what it did, which the
    /// tests hold against the preview. Undo puts the rules back as they were.
    @discardableResult
    func apply() async -> SenderRulePreview? {
        guard let pending else { return nil }
        self.pending = nil
        return await setRules(pending.rules, name: pending.title)
    }

    /// Saves `new`; a blocking rule that was added, turned on or edited then moves its sender's
    /// mail (GKM-072). One Undo takes back both the rules and those moves. `movesMail` is off
    /// while undoing and redoing: the moves are taken back, or made again, from their batch.
    private func setRules(_ new: [SenderRule], name: String, registersUndo: Bool = true,
                          movesMail: Bool = true) async -> SenderRulePreview? {
        guard let store else { return nil }
        let previous: [SenderRule], result: SenderRulePreview
        do {
            (previous, result) = try await store.setSenderRules(new)
        } catch {
            notice = String(describing: error)
            return nil
        }
        await refresh()
        await browser.reload()
        await onPlacementsChanged?()
        var moves: MailActionBatch?
        if movesMail {
            do {
                moves = try await moveBlockedMail(of: Self.blockingRulesChanged(from: previous, to: new), store: store)
            } catch {
                notice = String(describing: error)
            }
        }
        if registersUndo, let undoManager {
            undoManager.beginUndoGrouping()
            registerUndo(restoring: previous, moves: moves.map { batch in Task { batch } }, name: name)
            undoManager.endUndoGrouping()
        }
        archiveAtProvider(rules: new.filter(\.archiveAtProvider))
        return result
    }

    /// Undo puts `rules` back and takes back the mail the change moved; while undoing, the
    /// reverse is registered at once, so Redo works (as MailActions does, MAIL-037).
    private func registerUndo(restoring rules: [SenderRule], moves: Task<MailActionBatch?, Never>?, name: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let current = target.rules
                let step = Task { @MainActor [weak target] () -> MailActionBatch? in
                    guard let target else { return nil }
                    _ = await target.setRules(rules, name: name, registersUndo: false, movesMail: false)
                    guard let applied = await moves?.value else { return nil }
                    do {
                        return try await target.actions.takeBack(applied)
                    } catch {
                        target.notice = String(describing: error)
                        return nil
                    }
                }
                target.pendingUndo = Task { _ = await step.value }
                target.registerUndo(restoring: current, moves: moves == nil ? nil : step, name: name)
            }
        }
        undoManager?.setActionName(name)
    }

    /// The undo or redo in flight, for tests.
    @ObservationIgnored private(set) var pendingUndo: Task<Void, Never>?
    func waitForUndo() async { await pendingUndo?.value }

    // MARK: Provider archive (only for rules that ask for it)

    /// Archives, at the provider, the mail a rule silenced: only rules set to archive there,
    /// only what they silenced, through the action journal (Undo, offline queue, MAIL-034).
    private func archiveAtProvider(rules: [SenderRule]) {
        guard let store, !rules.isEmpty else { return }
        lastProviderArchive = Task { [weak self] in
            guard let self else { return }
            do {
                var ids: [MailMessageID] = []
                for rule in rules { ids += try await store.messagesSilenced(by: rule.id) }
                try await self.archive(ids, store: store)
            } catch {
                self.notice = String(describing: error)
            }
        }
    }

    /// After a sync: new mail that a provider-archiving rule silenced is archived too, and new
    /// mail from a blocked sender goes to Junk or Trash (GKM-072), with no Undo of its own: the
    /// rule moved it, not a step of yours. What arrived before the rule is left as it is now.
    func afterSync() async {
        guard let store else { return }
        let archiving = Set(rules.filter(\.archiveAtProvider).map(\.id))
        let blocking = Dictionary(blockingRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            var ids: [MailMessageID] = []
            var blocked: [String: [MailMessageID]] = [:]
            while true {
                let arrivals = try await store.arrivals(after: arrivalCursor, limit: 200)
                guard let last = arrivals.last else { break }
                arrivalCursor = last.sequence
                ids += arrivals.filter { $0.isSilenced && $0.senderRule.map(archiving.contains) == true }.map(\.id)
                for arrival in arrivals where arrival.disposition == .muted && arrival.spaces.isEmpty {
                    if let rule = arrival.senderRule, blocking[rule] != nil { blocked[rule, default: []].append(arrival.id) }
                }
            }
            if !ids.isEmpty { try await archive(ids, store: store) }
            var changes: [MailChange] = []
            for (id, arrived) in blocked {
                guard let rule = blocking[id] else { continue }
                changes += try await blockChanges(rule, ids: try await store.messagesToBlock(by: rule, among: arrived), store: store)
            }
            if !changes.isEmpty { _ = try await actions.write(changes) }
        } catch {
            notice = String(describing: error)
        }
        await refresh()
    }

    // MARK: Blocking (GKM-072)

    /// The blocking rules of `new` that are not in `old` as they are now: added, turned on or
    /// edited (an exclusion changed). Only these move mail when rules are saved, so mail you took
    /// out of Junk yourself is not moved again by an unrelated change.
    nonisolated static func blockingRulesChanged(from old: [SenderRule], to new: [SenderRule]) -> [SenderRule] {
        new.filter { rule in rule.action.blocks && rule.isEnabled && !old.contains(rule) }
    }

    /// Moves what these blocking rules decided, as one journal batch; returns it for Undo.
    private func moveBlockedMail(of rules: [SenderRule], store: MailStore) async throws -> MailActionBatch? {
        var changes: [MailChange] = []
        for rule in rules { changes += try await blockChanges(rule, ids: try await store.messagesToBlock(by: rule), store: store) }
        return try await actions.write(changes)
    }

    private func blockChanges(_ rule: SenderRule, ids: [MailMessageID], store: MailStore) async throws -> [MailChange] {
        guard !ids.isEmpty else { return [] }
        let messages = try await store.summaries(of: ids)
        return try await actions.plan(rule.action == .alwaysJunk ? .moveToJunk : .moveToTrash, messages: messages,
                                      in: .allMail, wholeThreads: false, store: store)
    }

    private func archive(_ ids: [MailMessageID], store: MailStore) async throws {
        var messages: [MessageSummary] = []
        for id in ids { if let summary = try await store.summary(of: id) { messages.append(summary) } }
        guard !messages.isEmpty else { return }
        await actions.perform(.archive, messages: messages, in: .allMail)
    }
}

extension SenderSummary {
    /// The name to show: the sender's display name, else the list or address.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return scope.name
    }

    var isList: Bool { scope.listID != nil }
}

/// Rules and their effects in words.
enum SenderRuleText {
    static let actions: [SenderRuleAction] = [.inbox, .silentArchive, .mute, .keepTransactionsOnly, .keepLatestOnly]
    /// Blocking a sender (GKM-072): Sil chose to offer both.
    static let blockActions: [SenderRuleAction] = [.alwaysJunk, .alwaysTrash]

    /// The folder a blocking rule moves mail to, for sentences.
    static func blockFolder(_ action: SenderRuleAction) -> String { action == .alwaysTrash ? "Trash" : "Junk" }

    /// The row menu's item: "Always Junk Mail from Deals…".
    static func blockMenuTitle(_ action: SenderRuleAction, name: String) -> String {
        "Always \(blockFolder(action)) Mail from \(name)…"
    }

    /// The row menu's item when the sender is blocked already.
    static func unblockMenuTitle(_ rule: SenderRule, name: String) -> String {
        "Stop Moving Mail from \(name) to \(blockFolder(rule.action))…"
    }

    /// What a rule change does at the provider and what it doesn't undo: shown above its preview.
    /// A blocking rule that is added, turned on or edited says how many messages it moves now;
    /// one that is removed or turned off says its mail stays where it was moved.
    static func blockNotes(current: [SenderRule], candidate: [SenderRule], preview: SenderRulePreview) -> [String] {
        var notes: [String] = []
        for rule in SendersModel.blockingRulesChanged(from: current, to: candidate) {
            let moving = preview.items.filter {
                $0.after.rule == rule.id && $0.after.disposition == .muted && !$0.isInTrashOrJunk && !$0.isExcluded
            }.count
            let folder = blockFolder(rule.action)
            let now = moving == 0 ? "No message moves now." : moving == 1 ? "1 message moves to \(folder) now." : "\(moving) messages move to \(folder) now."
            notes.append("\(now) This happens at your mail provider. New mail from \(rule.scope.name) goes to \(folder) after each check for mail, on this device and every other that has this rule. Flagged mail and mail in a space stay where they are. Undo puts it all back.")
        }
        for rule in current where rule.action.blocks && rule.isEnabled {
            let after = candidate.first { $0.id == rule.id }
            guard after == nil || after?.isEnabled == false else { continue }
            let folder = blockFolder(rule.action)
            notes.append("Mail from \(rule.scope.name) that was moved to \(folder) stays there: \(after == nil ? "removing" : "turning off") the rule doesn’t move it back. New mail is no longer moved.")
        }
        return notes
    }

    static func title(_ action: SenderRuleAction) -> String {
        switch action {
        case .inbox: "Always in Focused"
        case .silentArchive: "Archive Silently"
        case .category(let purpose): "Always in \(purpose.destinationTitle)"
        case .mute: "Mute"
        case .keepTransactionsOnly: "Keep Receipts Only"
        case .keepLatestOnly: "Keep Latest Only"
        case .alwaysJunk: "Always Junk"
        case .alwaysTrash: "Always Trash"
        }
    }

    static func explanation(_ action: SenderRuleAction) -> String {
        switch action {
        case .inbox: "Every message shows in Focused, unless it looks risky."
        case .silentArchive: "Out of Focused and silent; still in its category view."
        case .category(let purpose): "Every message goes to \(purpose.destinationTitle)."
        case .mute: "Out of Focused and the category views, silent. Still in All Mail. Account security mail always shows."
        case .keepTransactionsOnly: "Receipts, orders, invoices and account security mail stay; the rest is muted."
        case .keepLatestOnly: "The newest message stays; older ones are muted."
        case .alwaysJunk, .alwaysTrash:
            "Every message moves to \(blockFolder(action)) at your mail provider, now and as it arrives. Flagged mail, mail in a space and account security mail stay where they are."
        }
    }

    static func protection(_ protection: SenderRuleProtection) -> String {
        switch protection {
        case .risky: "Left alone: it looks risky. Rules never act on suspicious mail."
        case .corrected: "Left alone: you corrected this message yourself."
        case .security: "Left alone: account security mail always shows."
        case .transaction: "Kept: it’s a receipt, order or invoice."
        case .latest: "Kept: it’s the newest."
        case .flagged: "Stays where it is: it’s flagged."
        case .space: "Stays where it is: it’s in a space."
        }
    }

    static func effect(_ effect: SenderRuleEffect) -> String {
        switch effect {
        case .disposition(.inbox): "kept it in Focused"
        case .disposition(.archived): "archived it silently"
        case .disposition(.muted): "muted it"
        case .purpose(let purpose): "put it in \(purpose.destinationTitle)"
        case .protected(let protection): protection == .latest || protection == .transaction
            ? "kept it" : "matched, but left it alone"
        }
    }

    /// Where a preview item ends up: a blocking rule's mail goes to Junk or Trash.
    static func placement(_ placement: SenderPlacement?, rules: [SenderRule]) -> String {
        if let placement, placement.disposition == .muted, let id = placement.rule,
           let rule = rules.first(where: { $0.id == id }), rule.action.blocks {
            return blockFolder(rule.action)
        }
        return Self.placement(placement)
    }

    /// What the reader's "Why?" says the winning rule did.
    static func effect(_ effect: SenderRuleEffect, of rule: SenderRule) -> String {
        if rule.action.blocks, effect == .disposition(.muted) { return "moved it to \(blockFolder(rule.action))" }
        return Self.effect(effect)
    }

    static func placement(_ placement: SenderPlacement?) -> String {
        guard let placement else { return "Not sorted yet" }
        switch placement.disposition {
        case .muted: return "Muted"
        case .archived: return "\(placement.home.title), archived silently"
        case .inbox: return "Focused"
        case nil: return placement.home.title
        }
    }
}
