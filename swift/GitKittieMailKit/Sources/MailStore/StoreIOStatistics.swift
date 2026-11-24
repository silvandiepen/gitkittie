import Foundation
import os

/// Process-wide counts of what the store asked of the disk, for benchmarks and diagnostics
/// (GKM-035, docs/Performance.md). Counting is a lock and an addition per call; nothing here
/// changes what is written or when.
public enum StoreIOStatistics {
    public struct Snapshot: Sendable, Equatable {
        /// `fsync` calls on files the store wrote (messages, Markdown, blobs, journal entries).
        public var fileSyncs = 0
        /// `fsync` calls on directories, so a rename or removal in them is durable.
        public var directorySyncs = 0
        /// Files written through the atomic writer (each staged, flushed and renamed).
        public var filesWritten = 0
        /// Bytes in those files.
        public var bytesWritten: Int64 = 0
        /// Committed transactions on the index (`index.sqlite`, `synchronous = NORMAL`: no
        /// `fsync` per commit in WAL mode).
        public var indexCommits = 0
        /// Committed transactions on sync state (`state/<account>/sync.sqlite`; WAL at
        /// SQLite's default `synchronous = FULL`, so each commit flushes the WAL).
        public var syncStateCommits = 0

        public init() {}

        public static func - (lhs: Snapshot, rhs: Snapshot) -> Snapshot {
            var result = Snapshot()
            result.fileSyncs = lhs.fileSyncs - rhs.fileSyncs
            result.directorySyncs = lhs.directorySyncs - rhs.directorySyncs
            result.filesWritten = lhs.filesWritten - rhs.filesWritten
            result.bytesWritten = lhs.bytesWritten - rhs.bytesWritten
            result.indexCommits = lhs.indexCommits - rhs.indexCommits
            result.syncStateCommits = lhs.syncStateCommits - rhs.syncStateCommits
            return result
        }
    }

    private static let counters = OSAllocatedUnfairLock(initialState: Snapshot())

    /// The counts since the process started.
    public static func snapshot() -> Snapshot { counters.withLock { $0 } }

    static func record(_ change: (inout Snapshot) -> Void) { counters.withLock { change(&$0) } }
}
