import XCTest
@testable import GitKit

final class FolderSyncPlannerTests: XCTestCase {

    // MARK: First sync (empty base) — must be a safe union merge that never deletes.

    func testFirstSyncEmptyLocalPullsRemote() {
        let plan = FolderSyncPlanner.plan(
            base: [:],
            local: [:],
            remote: ["a.md": "sha_a", "dir/b.md": "sha_b"]
        )
        XCTAssertEqual(plan.downloads, ["a.md", "dir/b.md"])
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertTrue(plan.localDeletes.isEmpty)
        XCTAssertTrue(plan.remoteDeletes.isEmpty)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testFirstSyncEmptyRemotePushesLocal() {
        let plan = FolderSyncPlanner.plan(
            base: [:],
            local: ["a.md": "sha_a", "b.md": "sha_b"],
            remote: [:]
        )
        XCTAssertEqual(plan.uploads, ["a.md", "b.md"])
        XCTAssertTrue(plan.downloads.isEmpty)
    }

    func testFirstSyncUnionNeverDeletes() {
        // Both sides have files; some overlap identically, some are unique to each side.
        let plan = FolderSyncPlanner.plan(
            base: [:],
            local: ["same.md": "sha_same", "localonly.md": "sha_l"],
            remote: ["same.md": "sha_same", "remoteonly.md": "sha_r"]
        )
        XCTAssertEqual(plan.uploads, ["localonly.md"])   // push local-only up
        XCTAssertEqual(plan.downloads, ["remoteonly.md"]) // pull remote-only down
        XCTAssertTrue(plan.localDeletes.isEmpty, "first sync must never delete locally")
        XCTAssertTrue(plan.remoteDeletes.isEmpty, "first sync must never delete remotely")
        XCTAssertTrue(plan.conflicts.isEmpty)            // same.md identical → no action
    }

    func testFirstSyncSamePathDifferentContentIsConflictNotClobber() {
        let plan = FolderSyncPlanner.plan(
            base: [:],
            local: ["README.md": "sha_local"],
            remote: ["README.md": "sha_remote"]
        )
        XCTAssertEqual(plan.conflicts, ["README.md"])
        XCTAssertTrue(plan.uploads.isEmpty)
        XCTAssertTrue(plan.downloads.isEmpty)
    }

    // MARK: Ongoing sync (with a base) — deletions and updates relative to the base.

    func testRemoteDeletePropagatesToLocal() {
        let plan = FolderSyncPlanner.plan(
            base: ["gone.md": "sha1", "keep.md": "sha2"],
            local: ["gone.md": "sha1", "keep.md": "sha2"],
            remote: ["keep.md": "sha2"] // gone.md removed on remote
        )
        XCTAssertEqual(plan.localDeletes, ["gone.md"])
        XCTAssertTrue(plan.downloads.isEmpty)
        XCTAssertTrue(plan.uploads.isEmpty)
    }

    func testLocalDeletePropagatesToRemote() {
        let plan = FolderSyncPlanner.plan(
            base: ["gone.md": "sha1", "keep.md": "sha2"],
            local: ["keep.md": "sha2"], // gone.md removed locally
            remote: ["gone.md": "sha1", "keep.md": "sha2"]
        )
        XCTAssertEqual(plan.remoteDeletes, ["gone.md"])
        XCTAssertTrue(plan.localDeletes.isEmpty)
    }

    func testLocalModificationUploads() {
        let plan = FolderSyncPlanner.plan(
            base: ["a.md": "sha_old"],
            local: ["a.md": "sha_new"],
            remote: ["a.md": "sha_old"]
        )
        XCTAssertEqual(plan.uploads, ["a.md"])
    }

    func testRemoteModificationDownloads() {
        let plan = FolderSyncPlanner.plan(
            base: ["a.md": "sha_old"],
            local: ["a.md": "sha_old"],
            remote: ["a.md": "sha_new"]
        )
        XCTAssertEqual(plan.downloads, ["a.md"])
    }

    func testBothModifiedSameWayConverges() {
        // Both sides independently produced the same new content → nothing to do.
        let plan = FolderSyncPlanner.plan(
            base: ["a.md": "sha_old"],
            local: ["a.md": "sha_new"],
            remote: ["a.md": "sha_new"]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testBothModifiedDifferentlyConflicts() {
        let plan = FolderSyncPlanner.plan(
            base: ["a.md": "sha_old"],
            local: ["a.md": "sha_localnew"],
            remote: ["a.md": "sha_remotenew"]
        )
        XCTAssertEqual(plan.conflicts, ["a.md"])
    }

    func testDeletedOnOneSideModifiedOnOtherConflicts() {
        // Locally deleted, remotely modified — genuine conflict, don't resurrect or delete.
        let plan = FolderSyncPlanner.plan(
            base: ["a.md": "sha_old"],
            local: [:],
            remote: ["a.md": "sha_new"]
        )
        XCTAssertEqual(plan.conflicts, ["a.md"])
        XCTAssertTrue(plan.localDeletes.isEmpty)
        XCTAssertTrue(plan.remoteDeletes.isEmpty)
    }

    func testNoChangesIsEmpty() {
        let state = ["a.md": "sha1", "b.md": "sha2"]
        let plan = FolderSyncPlanner.plan(base: state, local: state, remote: state)
        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: Exclusions (ignore / selective sync) are inert — never delete.

    func testExcludedLocalOnlyFileIsNotUploaded() {
        let plan = FolderSyncPlanner.plan(
            base: [:],
            local: ["keep.md": "sha_k", ".DS_Store": "sha_ds"],
            remote: [:],
            isIgnored: { $0 == ".DS_Store" }
        )
        XCTAssertEqual(plan.uploads, ["keep.md"])
        XCTAssertFalse(plan.uploads.contains(".DS_Store"))
    }

    func testExcludingALocalFileNeverDeletesItFromRemote() {
        // A file exists everywhere, but is now excluded on this device. It must NOT be
        // seen as "locally deleted" and removed from the remote / other devices.
        let plan = FolderSyncPlanner.plan(
            base: ["big/asset.psd": "sha1", "keep.md": "sha2"],
            local: ["keep.md": "sha2"],                       // asset not materialized here
            remote: ["big/asset.psd": "sha1", "keep.md": "sha2"],
            isIgnored: { $0.hasPrefix("big/") }
        )
        XCTAssertTrue(plan.remoteDeletes.isEmpty, "excluding a file must never delete it remotely")
        XCTAssertTrue(plan.isEmpty, "an excluded, otherwise-unchanged tree yields no actions")
    }

    func testExcludedRemoteFileIsNotDownloaded() {
        let plan = FolderSyncPlanner.plan(
            base: [:],
            local: [:],
            remote: ["secrets/.env": "sha_env", "readme.md": "sha_r"],
            isIgnored: { $0.hasPrefix("secrets/") }
        )
        XCTAssertEqual(plan.downloads, ["readme.md"])
        XCTAssertFalse(plan.downloads.contains("secrets/.env"))
    }

    // MARK: Blob hashing matches git.

    func testGitBlobHashMatchesGit() {
        // `printf 'hello\n' | git hash-object --stdin` → ce013625030ba8dba906f756967f9e9ca394464a
        XCTAssertEqual(GitBlobHash.sha1(for: Data("hello\n".utf8)), "ce013625030ba8dba906f756967f9e9ca394464a")
        // Empty blob → e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        XCTAssertEqual(GitBlobHash.sha1(for: Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }
}
