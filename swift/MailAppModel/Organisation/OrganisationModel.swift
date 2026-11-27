import Foundation
import MailClassifier
import MailCore
import MailStore
import MailSync
import Observation

/// Why automatic organisation waits for an account (GKM-031, MAIL-117). Nil means it runs.
enum OrganisationPause: Equatable {
    /// Active mode is off for the account: virtual mode, nothing moves.
    case accountOff
    /// Another device runs it (its name).
    case otherDevice(String)
    /// No device runs it yet.
    case noCoordinator
    /// The provider can't be reached; destructive work waits until this device is back and
    /// has seen the provider's latest state.
    case offline
    /// The provider refused the password.
    case signInNeeded
    /// This device can't save mail right now (disk nearly full, or the mail folder can't be
    /// written): nothing moves at the provider until it can keep up again (GKM-091).
    case cannotStoreHere
    /// The sync hasn't finished a pass since it started: the state here may be behind.
    case reconciling
    /// Changes made here haven't all reached the provider yet.
    case changesWaiting(Int)

    /// Decides from the account's settings and its sync and journal as this device sees them.
    /// Automatic work needs: active mode on, this device the coordinator, the sync connected and
    /// done with a full pass (watching for changes), and an empty journal.
    static func check(_ settings: AccountOrganisation?, device: OrganisationDevice?, progress: SyncProgress?,
                      replay: ReplayProgress?) -> OrganisationPause? {
        guard let settings, settings.isActive else { return .accountOff }
        guard let coordinator = settings.coordinator else { return .noCoordinator }
        guard coordinator.id == device?.id else { return .otherDevice(coordinator.name) }
        guard let progress else { return .reconciling }
        switch progress.activity {
        case .waitingToRetry, .stopped: return .offline
        case .signInFailed: return .signInNeeded
        case .pausedForSpace, .cannotStore: return .cannotStoreHere
        case .starting, .connecting, .importing, .checking: return .reconciling
        case .watching: break
        }
        guard progress.lastCompletedPass != nil else { return .reconciling }
        if case .offline = replay?.activity { return .offline }
        if case .signInFailed = replay?.activity { return .signInNeeded }
        let waiting = (replay?.status.pending ?? 0) + (replay?.status.failed ?? 0)
        return waiting > 0 ? .changesWaiting(waiting) : nil
    }
}

/// Active organisation and retention (GKM-031; MAIL-115..119): active mode per account, retention
/// policies per category with their dry run, the coordinating device, the automatic runs after
/// each sync, and the audit log with Undo. UI-free; the views send intents.
///
/// Nothing moves at the provider until active mode is on for the account and the policy (or the
/// sender rule's "archive at your provider") is on. A policy is turned on from its dry run, which
/// then runs exactly as shown; afterwards it runs after each sync, on the coordinating device
/// only, and only while that device is online with an empty journal. Every run is in the audit
/// log and is undone from there.
@MainActor
@Observable
final class OrganisationModel {
    /// A policy's dry run, waiting to be looked at and, if you want, turned on.
    struct DryRun: Identifiable {
        var id: String { preview.id }
        var policy: RetentionPolicy
        var preview: CleanupPreview
    }

    private(set) var settings = OrganisationSettings()
    /// What active organisation did, newest first.
    private(set) var audit: [OrganisationAuditEntry] = []
    /// Why automatic work waits, per account with active mode on; absent when it runs.
    private(set) var pauses: [MailAccountID: OrganisationPause] = [:]
    private(set) var dryRun: DryRun?
    /// Messages that changed between the dry run and turning the policy on; nothing ran.
    private(set) var changedSinceDryRun: [CleanupDifference] = []
    /// What the last confirmed run did, for its result line and Undo.
    private(set) var lastRun: OrganisationAuditEntry?
    private(set) var device: OrganisationDevice?
    var notice: String?

    /// The clock, for tests.
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var store: MailStore?
    @ObservationIgnored private let actions: MailActions
    @ObservationIgnored private let sync: AccountSync
    @ObservationIgnored private var isRunning = false
    /// Mail a sender rule silenced while automatic work was paused: archived when it resumes.
    @ObservationIgnored private var waitingRuleArchives: [String: (account: MailAccountID, ids: Set<MailMessageID>)] = [:]

    init(actions: MailActions, sync: AccountSync) {
        self.actions = actions
        self.sync = sync
    }

    func attach(_ store: MailStore) async {
        self.store = store
        dryRun = nil
        lastRun = nil
        waitingRuleArchives = [:]
        do {
            device = try await store.organisationDevice(name: DeviceWords.model)
        } catch {
            notice = String(describing: error)
        }
        await refresh()
    }

    func refresh() async {
        guard let store else { return }
        do {
            settings = try await store.organisationSettings()
            audit = try await store.organisationAudit()
        } catch {
            notice = String(describing: error)
        }
        updatePauses()
    }

    // MARK: Reading

    func isActive(_ account: MailAccountID) -> Bool { settings.isActive(account) }

    /// The account's policy for a category: the one you saved, else the suggested one (off, not saved).
    func policy(for account: MailAccountID, category: MailCategory) -> RetentionPolicy {
        settings.retention.first { $0.account == account && $0.category == category }
            ?? RetentionPolicy(account: account, category: category)
    }

    /// True when this device runs the account's automatic work.
    func coordinatesHere(_ account: MailAccountID) -> Bool {
        settings.account(account)?.coordinator?.id == device?.id && device != nil
    }

    // MARK: Active mode per account

    /// Turns active mode on or off for an account. On moves nothing by itself: each policy is
    /// turned on from its own dry run, and a rule archives at the provider only when you set it
    /// to. This device coordinates when no device does yet. Off turns every policy of the account
    /// off and pauses sender rules' provider archive.
    func setActive(_ active: Bool, account: MailAccountID) async {
        await edit { settings in
            var entry = settings.account(account) ?? AccountOrganisation(account: account)
            entry.isActive = active
            if active, entry.coordinator == nil { entry.coordinator = self.device }
            entry.updatedAt = self.now()
            settings.set(entry)
            if !active {
                for var policy in settings.policies(for: account) where policy.isActive {
                    policy.isActive = false
                    policy.updatedAt = self.now()
                    settings.set(policy)
                }
            }
        }
        if !active { waitingRuleArchives = waitingRuleArchives.filter { $0.value.account != account } }
    }

    /// "Run on this Mac instead": this device becomes the one that runs the account's automatic
    /// work; the device that did stops once it has the new settings (GKM-026 brings them).
    func coordinateHere(_ account: MailAccountID) async {
        guard let device else { return }
        await edit { settings in
            var entry = settings.account(account) ?? AccountOrganisation(account: account)
            entry.coordinator = device
            entry.updatedAt = self.now()
            settings.set(entry)
        }
    }

    // MARK: Policies

    /// A new age or action. An active policy is turned off by it: what it would move changes,
    /// so it needs a new dry run before it runs again.
    func update(_ policy: RetentionPolicy, days: Int? = nil, action: RetentionAction? = nil) async {
        var changed = policy
        if let days { changed.days = days }
        if let action { changed.action = action }
        guard changed != policy else { return }
        changed.isActive = false
        changed.updatedAt = now()
        await edit { $0.set(changed) }
        if dryRun?.policy.id == policy.id { await preview(changed) }
    }

    /// The dry run: what the policy would move now and what it leaves alone. Writes nothing.
    func preview(_ policy: RetentionPolicy) async {
        guard let store else { return }
        guard let operation = operation(for: policy) else {
            notice = "This account’s folders aren’t known yet. Wait for the first sync to finish."
            return
        }
        changedSinceDryRun = []
        do {
            dryRun = DryRun(policy: policy, preview: try await store.previewRetention(policy, operation: operation, now: now()))
        } catch {
            notice = String(describing: error)
        }
    }

    func closeDryRun() {
        dryRun = nil
        changedSinceDryRun = []
    }

    /// Turns the policy of the dry run on, and runs that dry run exactly as shown (refused, with
    /// a fresh dry run, when anything in it changed). Needs active mode on for the account.
    func turnOn() async {
        guard let store, let dry = dryRun, let device else { return }
        guard settings.isActive(dry.policy.account) else {
            notice = OrganisationError.accountNotActive.description
            return
        }
        var policy = dry.policy
        policy.isActive = true
        policy.updatedAt = now()
        do {
            if !dry.preview.included.isEmpty {
                let entry = try await store.runRetention(dry.preview, policy: policy, trigger: .confirmed, device: device, now: now())
                lastRun = entry
                await actions.didWrite(accounts: [entry.account])
            }
        } catch CleanupError.previewChanged(let differences) {
            await preview(dry.policy)
            changedSinceDryRun = differences
            return
        } catch {
            notice = String(describing: error)
            return
        }
        await edit { settings in
            settings.set(policy)
            // The first policy turned on picks this device when none runs the account yet.
            if var entry = settings.account(policy.account), entry.coordinator == nil {
                entry.coordinator = device
                settings.set(entry)
            }
        }
        dryRun = nil
        changedSinceDryRun = []
    }

    /// Turns a policy off: it stops; what it moved stays where it is (undo that from the history).
    func turnOff(_ policy: RetentionPolicy) async {
        var off = policy
        off.isActive = false
        off.updatedAt = now()
        await edit { $0.set(off) }
    }

    // MARK: History

    /// Undoes one step of the history: what it moved goes back where it was. A policy that is
    /// still on is turned off, or its next run would move the same mail again (MAIL-118).
    func undo(_ entry: OrganisationAuditEntry) async {
        guard let store, let device else { return }
        do {
            if let inverse = try await store.undoOrganisation(entry.id, device: device, now: now()) {
                await actions.didWrite(accounts: inverse.accounts)
            } else {
                notice = "Nothing went back: every message has moved on since."
            }
            if lastRun?.id == entry.id { lastRun = nil }
        } catch {
            notice = String(describing: error)
            await refresh()
            return
        }
        await refresh()
        if case .retention(let id, _, _) = entry.source, let policy = settings.retention.first(where: { $0.id == id }), policy.isActive {
            await turnOff(policy)
            notice = OrganisationText.offAfterUndo(policy)
        }
    }

    // MARK: Automatic work

    /// After a sync: on the device that coordinates an account, while it is online and its
    /// journal is empty, every active policy runs its dry run again and runs it, and mail sender
    /// rules silenced while paused is archived. Elsewhere it says why it waits.
    func afterSync() async {
        guard let store, let device, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await refresh()
        for account in settings.accounts where account.isActive && pauses[account.account] == nil {
            for policy in settings.policies(for: account.account) where policy.isActive {
                guard let operation = operation(for: policy) else { continue }
                do {
                    let preview = try await store.previewRetention(policy, operation: operation, now: now())
                    guard !preview.included.isEmpty else { continue }
                    _ = try await store.runRetention(preview, policy: policy, trigger: .automatic, device: device, now: now())
                    await actions.didWrite(accounts: [account.account])
                } catch CleanupError.previewChanged {
                    // Mail changed between the dry run and the run: the next sync looks again.
                    continue
                } catch {
                    notice = String(describing: error)
                }
            }
            await archiveWaitingRuleMail(account: account.account)
        }
        await refresh()
    }

    /// Archives, at the provider, mail a sender rule silenced (MAIL-054), as one audited run.
    /// Needs active mode on for the account; after a sync (`automatic`) also the coordinating
    /// device, online with an empty journal: otherwise the mail waits here, sorted virtually.
    func archive(_ ids: [MailMessageID], silencedBy rule: SenderRule, trigger: OrganisationTrigger) async {
        guard let store, let device, !ids.isEmpty, settings.isActive(rule.account) else { return }
        if trigger == .automatic {
            updatePauses()
            guard pauses[rule.account] == nil else {
                var waiting = waitingRuleArchives[rule.id] ?? (rule.account, [])
                waiting.ids.formUnion(ids)
                waitingRuleArchives[rule.id] = waiting
                return
            }
        }
        do {
            let messages = try await store.summaries(of: ids)
            let changes = try await actions.plan(.archive, messages: messages, in: .allMail, wholeThreads: false, store: store)
            guard !changes.isEmpty,
                  let result = try await store.runRuleArchive(changes, rule: rule.id, account: rule.account, trigger: trigger,
                                                              device: device, now: now()) else { return }
            await actions.didWrite(accounts: result.batch.accounts)
        } catch {
            notice = String(describing: error)
        }
        await refresh()
    }

    private func archiveWaitingRuleMail(account: MailAccountID) async {
        guard let store else { return }
        let waiting = waitingRuleArchives.filter { $0.value.account == account }
        guard !waiting.isEmpty else { return }
        let rules = (try? await store.senderRules()) ?? []
        for (id, entry) in waiting {
            waitingRuleArchives[id] = nil
            guard let rule = rules.first(where: { $0.id == id }), rule.isEnabled, rule.archiveAtProvider else { continue }
            await archive(Array(entry.ids), silencedBy: rule, trigger: .automatic)
        }
    }

    // MARK: Helpers

    private func updatePauses() {
        var result: [MailAccountID: OrganisationPause] = [:]
        for entry in settings.accounts where entry.isActive {
            if let pause = OrganisationPause.check(entry, device: device, progress: sync.progress[entry.account],
                                                   replay: sync.replay[entry.account]) {
                result[entry.account] = pause
            }
        }
        pauses = result
    }

    private func operation(for policy: RetentionPolicy) -> CleanupOperation? {
        switch policy.action {
        case .archive: actions.archiveFolder(for: policy.account).map { .archive(to: $0.name, createTarget: $0.create) }
        case .trash: actions.trashFolder(for: policy.account).map { .trash(to: $0.name, createTarget: $0.create) }
        }
    }

    /// Reads the settings again, changes them and saves them, so a change made elsewhere since
    /// they were read is kept.
    private func edit(_ change: (inout OrganisationSettings) -> Void) async {
        guard let store else { return }
        do {
            var current = try await store.organisationSettings()
            change(&current)
            try await store.saveOrganisationSettings(current)
        } catch {
            notice = String(describing: error)
        }
        await refresh()
    }
}

/// Organisation in words, shared by the Mac and the iPhone and iPad apps.
enum OrganisationText {
    static func category(_ category: MailCategory) -> String {
        switch category {
        case .subscriptions: "Newsletters and subscriptions"
        case .promotions: "Promotions"
        case .updates: "Routine updates"
        case .focused: "Focused"
        case .transactions: "Receipts and orders"
        case .quarantine: "Spam"
        }
    }

    static func days(_ days: Int) -> String {
        switch days {
        case 7: "1 week"
        case 14: "2 weeks"
        case 30: "30 days"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    static func action(_ action: RetentionAction) -> String {
        switch action {
        case .archive: "Archive"
        case .trash: "Move to Trash"
        }
    }

    /// "Archive promotions older than 30 days".
    static func policy(_ policy: RetentionPolicy) -> String {
        "\(action(policy.action)) \(category(policy.category).lowercased()) older than \(days(policy.days))"
    }

    static func pause(_ pause: OrganisationPause?) -> String {
        switch pause {
        case nil: "Runs on \(DeviceWords.this) after each check for mail."
        case .accountOff: "Off: mail is sorted on your devices only and stays where it is at your provider."
        case .otherDevice(let name): "Runs on your \(name). \(DeviceWords.thisAtStart) only shows what it would do."
        case .noCoordinator: "No device runs it yet."
        case .offline: "Paused: \(DeviceWords.this) is offline. It runs again once it’s back online and up to date."
        case .signInNeeded: "Paused: sign in to this account again."
        case .cannotStoreHere: "Paused: \(DeviceWords.this) can’t save mail right now. It runs again once it can."
        case .reconciling: "Waiting for the check for mail to finish."
        case .changesWaiting(let count): "Waiting: \(count == 1 ? "1 change" : "\(count) changes") still on the way to your provider."
        }
    }

    static func trigger(_ entry: OrganisationAuditEntry) -> String {
        entry.trigger == .confirmed ? "When you turned it on" : "Automatically"
    }

    /// What an entry did, in words, without mail content: "Archived 12 messages".
    static func summary(_ entry: OrganisationAuditEntry) -> String {
        let messages = entry.count == 1 ? "1 message" : "\(entry.count) messages"
        return entry.action == .trash ? "Moved \(messages) to Trash" : "Archived \(messages)"
    }

    /// What made it: a policy (as it was when it ran) or a sender rule.
    static func source(_ entry: OrganisationAuditEntry, rules: [SenderRule]) -> String {
        switch entry.source {
        case .retention(_, let kind, let age): "\(Self.category(kind)) older than \(Self.days(age))"
        case .senderRule(let id):
            rules.first { $0.id == id }.map { "Sender rule for \($0.scope.name)" } ?? "A sender rule you removed"
        }
    }

    /// The dry run's first line: nothing has moved, and what would.
    static func dryRun(_ preview: CleanupPreview) -> String {
        guard !preview.included.isEmpty else { return "Dry run: nothing has moved, and no message would move now." }
        let count = CleanupText.messages(preview.included.count)
        return switch preview.operation {
        case .archive(let target, _): "Dry run: nothing has moved. \(count) would move from your inbox to “\(target)” at your mail provider."
        case .trash(let target, _): "Dry run: nothing has moved. \(count) would move to “\(target)” at your mail provider."
        case .move(let folder): "Dry run: nothing has moved. \(count) would move to “\(folder)” at your mail provider."
        }
    }

    static func offAfterUndo(_ policy: RetentionPolicy) -> String {
        "“\(Self.policy(policy))” is off now, so it doesn’t move them again. To keep some messages for good, flag them or add them to a space, then turn the policy on from its dry run."
    }

    static let trashNote = "Your mail provider may empty its Trash by itself, often after 30 days. Archive keeps mail until you delete it."
}
