import Foundation
import CryptoKit

// Git-free folder sync model types, shared by GitFolder (and reusable elsewhere).
//
// The engine syncs a local folder tree against a hosted repo over the REST API — no
// local clone, no `git` binary. These types are the pure, testable core: a manifest
// (the last-synced base), a planner that diffs local vs remote against that base, and a
// progress model so the UI can show exactly what sync is doing.

/// The last successfully-synced state of a folder: the remote commit it matched and the
/// blob SHA of every file at that point. Persisted per folder in the app container (never
/// inside the synced folder). Acts as the three-way-merge *base*.
public struct SyncManifest: Codable, Equatable, Sendable {
    /// The remote commit SHA this manifest was synced to (nil before the first sync).
    public var commitSHA: String?
    /// Path → git blob SHA for every file at the last sync.
    public var entries: [String: String]

    public init(commitSHA: String? = nil, entries: [String: String] = [:]) {
        self.commitSHA = commitSHA
        self.entries = entries
    }

    public static let empty = SyncManifest()
}

/// The git blob SHA-1 of file content — identical to what GitHub reports for a tree
/// entry, so local files can be compared to remote entries by SHA with no downloads.
public enum GitBlobHash {
    public static func sha1(for data: Data) -> String {
        var header = Data("blob \(data.count)".utf8)
        header.append(0)
        var digest = Insecure.SHA1()
        digest.update(data: header)
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A resolved set of actions to reconcile local and remote against the base. Paths only —
/// the engine resolves content from the local disk / remote blob SHAs. Deletes are only
/// ever produced relative to the base, so a first sync (empty base) yields none.
public struct FolderSyncPlan: Equatable, Sendable {
    /// Remote add/modify → write to local disk.
    public var downloads: [String] = []
    /// Local add/modify → upload to remote in the next commit.
    public var uploads: [String] = []
    /// File removed on the remote since base → delete from local disk.
    public var localDeletes: [String] = []
    /// File removed locally since base → delete from remote in the next commit.
    public var remoteDeletes: [String] = []
    /// Same path changed differently on both sides → left untouched, surfaced to the user.
    public var conflicts: [String] = []

    /// Nothing to do (and nothing conflicting).
    public var isEmpty: Bool {
        downloads.isEmpty && uploads.isEmpty && localDeletes.isEmpty
            && remoteDeletes.isEmpty && conflicts.isEmpty
    }

    /// Changes that require a new remote commit.
    public var hasRemoteWrites: Bool { !uploads.isEmpty || !remoteDeletes.isEmpty }
    /// Changes that touch the local disk.
    public var hasLocalWrites: Bool { !downloads.isEmpty || !localDeletes.isEmpty }
}

/// Diffs local vs remote against the base and produces a `FolderSyncPlan`. Pure and
/// deterministic — the safety guarantees (below) are enforced here and covered by tests.
///
/// Guarantees:
/// - A path is deleted on a side **only** if the base proves it was previously synced and
///   then removed on the other side. A first sync (empty base) therefore never deletes.
/// - A path that changed on both sides to *different* content is a conflict: neither side
///   is touched.
public enum FolderSyncPlanner {
    /// - Parameters:
    ///   - base: path → blob SHA from the manifest (empty on first sync).
    ///   - local: path → blob SHA scanned from the local folder.
    ///   - remote: path → blob SHA from the remote tree.
    ///   - isIgnored: paths for which this returns true are excluded from sync entirely —
    ///     never uploaded, downloaded, or deleted on either side. Exclusion is never a delete.
    public static func plan(
        base: [String: String],
        local: [String: String],
        remote: [String: String],
        isIgnored: (String) -> Bool = { _ in false }
    ) -> FolderSyncPlan {
        var plan = FolderSyncPlan()
        let paths = Set(base.keys).union(local.keys).union(remote.keys)

        for path in paths {
            // Excluded/offloaded paths are invisible to the diff: no upload, no download,
            // and crucially no delete — so excluding a file never removes it anywhere.
            if isIgnored(path) { continue }

            let b = base[path]
            let l = local[path]
            let r = remote[path]

            let localChanged = l != b
            let remoteChanged = r != b

            switch (localChanged, remoteChanged) {
            case (false, false):
                continue // in sync
            case (true, false):
                // Only the local side moved: make the remote match it.
                if l == nil { plan.remoteDeletes.append(path) } else { plan.uploads.append(path) }
            case (false, true):
                // Only the remote side moved: make the local disk match it.
                if r == nil { plan.localDeletes.append(path) } else { plan.downloads.append(path) }
            case (true, true):
                // Both moved. Converged to the same content → no action. Otherwise conflict.
                if l == r { continue } else { plan.conflicts.append(path) }
            }
        }

        plan.downloads.sort()
        plan.uploads.sort()
        plan.localDeletes.sort()
        plan.remoteDeletes.sort()
        plan.conflicts.sort()
        return plan
    }
}

/// What the engine is currently doing, streamed to the UI during a sync.
public enum FolderSyncPhase: Equatable, Sendable {
    case preparing
    case scanningLocal
    case fetchingRemote
    case downloading(file: String)
    case uploading(file: String)
    case committing
    case writingLocal(file: String)
    case done
}

/// A single progress update. `completedUnits`/`totalUnits` drive a determinate bar once
/// the plan is known; `message` is a short human line ("Downloading notes.md — 12 of 340").
public struct FolderSyncProgress: Equatable, Sendable {
    public var phase: FolderSyncPhase
    public var message: String
    public var completedUnits: Int
    public var totalUnits: Int

    public init(phase: FolderSyncPhase, message: String, completedUnits: Int = 0, totalUnits: Int = 0) {
        self.phase = phase
        self.message = message
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }

    public var fractionComplete: Double {
        totalUnits > 0 ? min(1, Double(completedUnits) / Double(totalUnits)) : 0
    }
}
