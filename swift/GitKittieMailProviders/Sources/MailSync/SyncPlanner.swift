import Foundation
import MailProvider

/// The sync's decisions as plain functions of what the provider and the store report, so they
/// can be tested without a server: folder order, what to import now and what later, how to
/// batch the downloads, and the storage budget.
public enum SyncPlanner {
    /// What to do in one folder.
    public struct FolderPlan: Sendable, Equatable {
        /// Import now, newest first: new mail, and on a first sync the newest messages.
        public var recent: [UInt32]
        /// Import after every folder's recent mail, newest first, within the storage budget.
        public var history: [UInt32]
        /// History left out by the window (received before it): not imported (GKM-039).
        public var older: [UInt32] = []
        /// UIDs this device has on record that the provider no longer has: expunged or moved.
        public var gone: [UInt32]
        /// The cursor to checkpoint once `recent` is stored.
        public var highestUID: UInt32
    }

    /// Splits a folder's UIDs into what to fetch now, what later, and what is gone.
    ///
    /// The store's mapping is the exact record of what is stored, so "missing" is computed
    /// from it, never from the cursor: a cursor that lags after a crash costs nothing, and one
    /// can never skip a message. The cursor only separates new mail (above it) from history.
    ///
    /// - Parameters:
    ///   - serverUIDs: every UID the provider listed, any order.
    ///   - known: the UIDs stored for this folder at the current UIDVALIDITY.
    ///   - cursor: the checkpointed highest UID, or nil on a first sync (or after a reset).
    ///   - recentLimit: on a first sync, how many of the newest messages count as recent.
    ///   - olderThanWindow: UIDs received before the history window (GKM-039); `nil` without a
    ///     window. They are left out of the history, and on a first sync out of the recent mail
    ///     too; new mail (above the cursor) always comes in, whatever its date.
    public static func plan(serverUIDs: [UInt32], known: Set<UInt32>, cursor: UInt32?, recentLimit: Int,
                            olderThanWindow: Set<UInt32>? = nil) -> FolderPlan {
        let server = Set(serverUIDs)
        let missing = server.subtracting(known).sorted(by: >)
        let gone = known.subtracting(server).sorted()
        let highest = max(cursor ?? 0, serverUIDs.max() ?? 0)
        let candidates = cursor.map { cursor in missing.filter { $0 <= cursor } } ?? missing
        let (older, wanted) = split(candidates, olderThanWindow: olderThanWindow)
        guard let cursor else {
            let recent = Array(wanted.prefix(max(0, recentLimit)))
            return FolderPlan(recent: recent, history: Array(wanted.dropFirst(recent.count)), older: older, gone: gone,
                              highestUID: highest)
        }
        return FolderPlan(recent: missing.filter { $0 > cursor }, history: wanted, older: older, gone: gone, highestUID: highest)
    }

    /// The missing UIDs a history window decides about, newest first: on a first sync (no
    /// cursor) every missing message, afterwards those at or below the cursor. New mail above
    /// the cursor is never one of them.
    public static func historyCandidates(serverUIDs: [UInt32], known: Set<UInt32>, cursor: UInt32?) -> [UInt32] {
        let missing = Set(serverUIDs).subtracting(known).sorted(by: >)
        guard let cursor else { return missing }
        return missing.filter { $0 <= cursor }
    }

    /// Candidates received before the window, and the rest, both in the order given.
    private static func split(_ candidates: [UInt32], olderThanWindow: Set<UInt32>?) -> (older: [UInt32], wanted: [UInt32]) {
        guard let window = olderThanWindow, !window.isEmpty else { return ([], candidates) }
        var older: [UInt32] = []
        var wanted: [UInt32] = []
        for uid in candidates {
            if window.contains(uid) { older.append(uid) } else { wanted.append(uid) }
        }
        return (older, wanted)
    }

    /// The first day of a history window of `days` days ending `now`: midnight UTC, `days`
    /// days before today (IMAP compares received dates by calendar day).
    public static func windowStart(days: Int, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -max(0, days), to: today) ?? today
    }

    /// The order folders are synced in: the inbox first, then what people look at most;
    /// virtual and disposable folders last. Within a rank the provider's order is kept.
    public static func order(_ folders: [RemoteFolder]) -> [RemoteFolder] {
        func rank(_ folder: RemoteFolder) -> Int {
            switch folder.role {
            case .inbox: 0
            case .sent: 1
            case .drafts: 2
            case .archive: 3
            case nil: 4
            case .flagged: 5
            case .all: 6
            case .junk: 7
            case .trash: 8
            }
        }
        return folders.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Groups messages (in the order given) into downloads of at most `maxMessages` messages
    /// and `maxBytes` bytes; a single message larger than `maxBytes` goes alone. Messages over
    /// `maxMessageSize` cannot be held in memory and are returned separately, to be reported.
    public static func batches(_ summaries: [RemoteMessageSummary], maxMessages: Int, maxBytes: Int,
                               maxMessageSize: Int) -> (batches: [[RemoteMessageSummary]], tooLarge: [RemoteMessageSummary]) {
        var batches: [[RemoteMessageSummary]] = []
        var tooLarge: [RemoteMessageSummary] = []
        var current: [RemoteMessageSummary] = []
        var bytes = 0
        for summary in summaries {
            let size = summary.size ?? 0
            if size > maxMessageSize { tooLarge.append(summary); continue }
            if !current.isEmpty, current.count >= maxMessages || bytes + size > maxBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(summary)
            bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return (batches, tooLarge)
    }

    /// True when downloading `next` more bytes of history stays within the budget. New mail
    /// is never held back by the budget: only history is.
    public static func budgetAllows(alreadyImported: Int64, next: Int64, budget: Int64?) -> Bool {
        guard let budget else { return true }
        return alreadyImported + next <= budget
    }

    /// Splits a list into chunks of at most `size`.
    public static func chunks<Element>(_ items: [Element], of size: Int) -> [[Element]] {
        let size = max(1, size)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}
