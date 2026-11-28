import Foundation
import MailCore

// Mail deleted at the provider (GKM-011, answered by Sil; MAIL-075). Deleted elsewhere (in
// Apple Mail, on the web, on a phone), a message keeps its local copy and is shown as
// "Deleted at <provider>" with the time. Only when the person turns on "Remove mail deleted
// elsewhere" for the account does the local copy go, and even then never one that is pinned,
// in a space, or still in the action journal (an open change, or Undo's seven days).

/// A noticed deletion the sync is to check: its stored Message-ID, to search the folders whose
/// mail is not all downloaded here, and how its earlier checks went (MAIL-105).
public struct DeletionCandidate: Equatable, Sendable {
    public var id: MailMessageID
    public var messageID: String?
    public var noticedAt: Date
    /// When a check at the provider last could not tell whether it is gone; `nil` when none
    /// has failed to.
    public var checkedAt: Date?
    /// Checks in a row that could not tell.
    public var undecidedChecks: Int

    public init(id: MailMessageID, messageID: String?, noticedAt: Date, checkedAt: Date? = nil, undecidedChecks: Int = 0) {
        self.id = id
        self.messageID = messageID
        self.noticedAt = noticedAt
        self.checkedAt = checkedAt
        self.undecidedChecks = undecidedChecks
    }
}

/// Why a local copy of mail deleted at the provider stays even with removal turned on.
public enum DeletionKeep: Equatable, Sendable {
    case pinned, inSpace, inActionJournal
}

extension MailStore {
    /// Messages that left their last folder at the provider and are not confirmed yet, in the
    /// order to check them: those no check has failed to decide first, oldest first, then the
    /// least recently checked (MAIL-105). Ones that have a location again or are no longer
    /// stored here are dropped.
    public func deletionCandidates(account: MailAccountID) throws -> [DeletionCandidate] {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        var result: [DeletionCandidate] = []
        for notice in try mapping.unconfirmedDeletions() {
            guard try mapping.locations(of: notice.id).isEmpty else {
                try mapping.clearDeletion(of: notice.id)
                continue
            }
            guard try index.contains(notice.id) else {
                try mapping.clearDeletion(of: notice.id) // not stored here any more
                continue
            }
            result.append(DeletionCandidate(id: notice.id, messageID: try index.messageIDHeader(of: notice.id), noticedAt: notice.noticedAt,
                                            checkedAt: notice.checkedAt, undecidedChecks: notice.undecidedChecks))
        }
        return result
    }

    /// A check at the provider could not tell whether the message is gone (MAIL-104): it is not
    /// marked, and it goes behind the candidates that have not been checked since (MAIL-105).
    public func recordUndecidedDeletionCheck(of id: MailMessageID, account: MailAccountID, now: Date = Date()) throws {
        try mapping(for: SafePath.component(account.rawValue)).recordUndecidedCheck(of: id, at: now)
    }

    /// The provider has the message after all, in a folder whose mail this device has not all
    /// downloaded: not deleted. It is matched to that copy when the sync downloads it.
    public func dismissDeletion(of id: MailMessageID, account: MailAccountID) throws {
        try mapping(for: SafePath.component(account.rawValue)).clearDeletion(of: id)
    }

    /// Confirms that these messages are gone at the provider: from now on they are shown as
    /// deleted there, at the time the sync first noticed it.
    public func confirmDeletions(_ candidates: [DeletionCandidate], account: MailAccountID, now: Date = Date()) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try index.batch {
            for candidate in candidates {
                try mapping.confirmDeletion(of: candidate.id, at: now)
                try index.setDeletedAtProvider(candidate.noticedAt, for: candidate.id)
            }
        }
    }

    /// Messages of the account shown as deleted at the provider, with when.
    public func deletedAtProvider(account: MailAccountID) throws -> [MailMessageID: Date] {
        try mapping(for: SafePath.component(account.rawValue)).confirmedDeletions()
    }

    /// Why the local copy of `id` stays even when removal is on; `nil` when it may go.
    public func deletionKeep(_ id: MailMessageID, account: MailAccountID) throws -> DeletionKeep? {
        if try !pinnedMessageIDs(among: [id]).isEmpty { return .pinned }
        if try index.isInSpace(id) { return .inSpace }
        if try mapping(for: SafePath.component(account.rawValue)).hasActions(for: id) { return .inActionJournal }
        return nil
    }

    /// "Remove mail deleted elsewhere" (MAIL-075): deletes the local copy of every confirmed
    /// provider deletion of the account that nothing keeps (pinned, in a space, in the action
    /// journal). Returns the messages removed. The `.eml` goes first after the index row: a
    /// crash in between leaves the copy, which the next rebuild shows again, never a half.
    @discardableResult
    public func removeMailDeletedAtProvider(account: MailAccountID) throws -> [MailMessageID] {
        let name = try SafePath.component(account.rawValue)
        let mapping = try mapping(for: name)
        var removed: [MailMessageID] = []
        for id in try mapping.confirmedDeletions().keys.sorted() {
            guard try mapping.locations(of: id).isEmpty else {
                try mapping.clearDeletion(of: id)
                try index.setDeletedAtProvider(nil, for: id)
                continue
            }
            guard try deletionKeep(id, account: account) == nil else { continue }
            try removeLocalCopy(id, accountName: name)
            try mapping.removeMessageState(id)
            removed.append(id)
        }
        if !removed.isEmpty {
            try removeUnreferencedBlobs()
            invalidateClassificationContext()
        }
        return removed
    }

    /// Deletes one message's files and its index row. Partial messages (GKM-036) live in the
    /// device folder; their cached parts become unreferenced and go with the next eviction.
    private func removeLocalCopy(_ id: MailMessageID, accountName: String) throws {
        try requireWritable()
        let fileManager = FileManager.default
        let stored = try? message(id)
        try index.remove(id)
        if let stored, !stored.isPartial {
            if fileManager.fileExists(atPath: stored.emlURL.path) { try fileManager.removeItem(at: stored.emlURL) }
            if fileManager.fileExists(atPath: stored.markdownURL.path) { try fileManager.removeItem(at: stored.markdownURL) }
        }
        try removePartialFiles(id, account: accountName)
    }

    /// Copies the confirmed deletions into a rebuilt index.
    func restoreProviderDeletions(account: MailAccountID, mapping: RemoteMapping) throws {
        let confirmed = try mapping.confirmedDeletions()
        guard !confirmed.isEmpty else { return }
        try index.batch {
            for (id, date) in confirmed { try index.setDeletedAtProvider(date, for: id) }
        }
    }
}

extension MailIndex {
    func contains(_ id: MailMessageID) throws -> Bool {
        try database.prepare("SELECT 1 FROM messages WHERE local_id = ?").bind([.text(id.rawValue)]).step()
    }

    /// The stored message's Message-ID header; `nil` when it has none.
    func messageIDHeader(of id: MailMessageID) throws -> String? {
        let statement = try database.prepare("SELECT message_id FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? statement.text(0) : nil
    }
}
