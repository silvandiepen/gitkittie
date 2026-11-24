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
    public static func plan(serverUIDs: [UInt32], known: Set<UInt32>, cursor: UInt32?, recentLimit: Int) -> FolderPlan {
        let server = Set(serverUIDs)
        let missing = server.subtracting(known).sorted(by: >)
        let gone = known.subtracting(server).sorted()
        let highest = max(cursor ?? 0, serverUIDs.max() ?? 0)
        guard let cursor else {
            let recent = Array(missing.prefix(max(0, recentLimit)))
            return FolderPlan(recent: recent, history: Array(missing.dropFirst(recent.count)), gone: gone, highestUID: highest)
        }
        return FolderPlan(recent: missing.filter { $0 > cursor }, history: missing.filter { $0 <= cursor },
                          gone: gone, highestUID: highest)
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
