import Foundation
import MailClassifier
import MailCore

// Active organisation and retention in the store (GKM-031; Organisation.swift has the types,
// MAIL-115..119 the decisions).
//
// A retention policy is a cleanup group (`CleanupGroupID.Kind.olderThan`), so its dry run is the
// cleanup preview (MAIL-060) with every protection of MAIL-059, and its run is `runCleanup`: the
// preview made again from the latest state in the same actor step that writes the journal. What
// is added here is the gate (active mode for the account, the policy on, this device the
// coordinator) checked in that same step, and the audit entry written with the run.

extension MailStore {
    // MARK: - Settings

    /// Your organisation settings: active mode per account, the coordinating device, retention
    /// policies. Read from the file every time, so a change another device made (GKM-026) or a
    /// policy just turned off is what a run checks.
    public func organisationSettings() throws -> OrganisationSettings {
        try OrganisationSettings.load(from: OrganisationSettings.url(in: locations.deviceFolder))
    }

    public func saveOrganisationSettings(_ settings: OrganisationSettings) throws {
        var settings = settings
        settings.version = OrganisationSettings.currentVersion
        try writer.write(JSONCoding.prettyEncoder.encode(settings), to: OrganisationSettings.url(in: locations.deviceFolder))
    }

    /// This device, as organisation settings and the audit log name it.
    public func organisationDevice(name: String) throws -> OrganisationDevice {
        OrganisationDevice(id: try locations.deviceIdentifier(), name: name)
    }

    // MARK: - Dry run

    /// What the policy would do now: the exact cleanup preview of its group (what moves, from
    /// where to where, and what is protected and why). Writes nothing, whether or not the policy
    /// or the account is active.
    public func previewRetention(_ policy: RetentionPolicy, operation: CleanupOperation, now: Date = Date()) throws -> CleanupPreview {
        try previewCleanup(policy.group, operation: operation, options: CleanupOptions(), now: now)
    }

    // MARK: - Running

    /// Runs a policy's preview and writes the audit entry, in one step of this actor.
    ///
    /// Refuses, and moves nothing, unless active mode is on for the account and, for an
    /// automatic run, the policy is still on as previewed and `device` is the account's
    /// coordinating device. Then it is `runCleanup`: refused when anything previewed changed.
    /// `confirmed` is the run of the dry run you turned the policy on from.
    @discardableResult
    public func runRetention(_ preview: CleanupPreview, policy: RetentionPolicy, trigger: OrganisationTrigger,
                             device: OrganisationDevice, excluding excluded: Set<MailMessageID> = [],
                             now: Date = Date()) throws -> OrganisationAuditEntry {
        let settings = try organisationSettings()
        guard settings.isActive(policy.account), preview.group == policy.group else { throw OrganisationError.accountNotActive }
        if trigger == .automatic {
            guard let current = settings.retention.first(where: { $0.id == policy.id }), current.isActive,
                  current.group == policy.group, current.action == policy.action else { throw OrganisationError.policyChanged }
            guard settings.account(policy.account)?.coordinator?.id == device.id else { throw OrganisationError.notCoordinator }
        }
        let run = try runCleanup(preview, excluding: excluded, now: now)
        let changes = preview.included.filter { !excluded.contains($0.id) }.flatMap(\.changes)
        return try recordOrganisation(batch: run.batch, changes: changes, account: policy.account,
                                      source: .retention(policy: policy.id, category: policy.category, days: policy.days),
                                      trigger: trigger, action: policy.action, device: device, now: now)
    }

    /// Writes a sender rule's provider archive (MAIL-054) as one journal batch and its audit
    /// entry, in one step. Refused unless active mode is on for the account; an automatic run
    /// also needs `device` to be its coordinating device. Flagged mail and mail in a space are
    /// left where they are, read at this moment (MAIL-116, as Clean Up and blocking do). Returns
    /// nil when nothing changed.
    public func runRuleArchive(_ changes: [MailChange], rule: String, account: MailAccountID, trigger: OrganisationTrigger,
                               device: OrganisationDevice, now: Date = Date()) throws -> (batch: MailActionBatch, entry: OrganisationAuditEntry)? {
        let settings = try organisationSettings()
        guard settings.isActive(account) else { throw OrganisationError.accountNotActive }
        if trigger == .automatic, settings.account(account)?.coordinator?.id != device.id { throw OrganisationError.notCoordinator }
        let mine = try changes.filter { change in
            guard try index.account(of: change.message) == account, try !index.isInSpace(change.message) else { return false }
            return try !flags(of: change.message).flagged
        }
        guard let batch = try perform(mine, now: now) else { return nil }
        let entry = try recordOrganisation(batch: batch, changes: mine, account: account, source: .senderRule(rule), trigger: trigger,
                                           action: .archive, device: device, now: now)
        return (batch, entry)
    }

    private func recordOrganisation(batch: MailActionBatch, changes: [MailChange], account: MailAccountID, source: OrganisationSource,
                                    trigger: OrganisationTrigger, action: RetentionAction, device: OrganisationDevice,
                                    now: Date) throws -> OrganisationAuditEntry {
        let moves = changes.compactMap { change -> OrganisationAuditEntry.Move? in
            guard case .move(let from, let to, _) = change.action else { return nil }
            return OrganisationAuditEntry.Move(message: change.message, from: from, to: to)
        }
        let entry = OrganisationAuditEntry(id: UUID().uuidString.lowercased(), date: now, device: device, account: account,
                                           source: source, trigger: trigger, action: action, count: batch.count, batch: batch.id,
                                           moves: moves)
        var log = try auditLog()
        log.entries.append(entry)
        if log.entries.count > OrganisationAuditLog.limit { log.entries.removeFirst(log.entries.count - OrganisationAuditLog.limit) }
        try saveAuditLog(log)
        return entry
    }

    // MARK: - The audit log

    /// What active organisation did, newest first: when, which account, what made it, how many
    /// messages, which device, and whether it was undone. No mail content.
    public func organisationAudit(account: MailAccountID? = nil) throws -> [OrganisationAuditEntry] {
        try auditLog().entries.filter { account == nil || $0.account == account }.reversed()
    }

    /// Undoes one entry: its journal batch while the journal still has it (MAIL-037: open rows
    /// cancel out, sent moves go back), else each recorded move back, for every message still
    /// where it was moved to. Only on the device that made it. Returns the batch that undoes it,
    /// or nil when nothing could go back (every message moved on since).
    @discardableResult
    public func undoOrganisation(_ id: String, device: OrganisationDevice, now: Date = Date()) throws -> MailActionBatch? {
        var log = try auditLog()
        guard let index = log.entries.firstIndex(where: { $0.id == id }) else { throw OrganisationError.entryNotFound }
        let entry = log.entries[index]
        guard entry.device.id == device.id else { throw OrganisationError.madeOnAnotherDevice(entry.device.name) }
        guard !entry.isUndone else { throw OrganisationError.alreadyUndone }
        var inverse = try undo(MailActionBatch(id: entry.batch, accounts: [entry.account], count: entry.count), now: now)
        if inverse == nil {
            // The journal let go of the batch (settled rows stay seven days, MAIL-037).
            var back: [MailChange] = []
            for move in entry.moves {
                guard try self.index.account(of: move.message) != nil else { continue }
                let boxes = try effectiveMailboxes(of: move.message)
                if boxes.contains(move.to), !boxes.contains(move.from) {
                    back.append(MailChange(move.message, .move(from: move.to, to: move.from)))
                }
            }
            inverse = try perform(back, now: now)
        }
        log.entries[index].undoneAt = now
        log.entries[index].restored = inverse?.count ?? 0
        try saveAuditLog(log)
        return inverse
    }

    private func auditLog() throws -> OrganisationAuditLog {
        try OrganisationAuditLog.load(from: OrganisationAuditLog.url(in: locations.deviceFolder))
    }

    private func saveAuditLog(_ log: OrganisationAuditLog) throws {
        try writer.write(JSONCoding.prettyEncoder.encode(log), to: OrganisationAuditLog.url(in: locations.deviceFolder))
    }
}
