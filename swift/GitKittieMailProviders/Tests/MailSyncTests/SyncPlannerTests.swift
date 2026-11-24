import XCTest
import MailProvider
@testable import MailSync

/// The sync's decisions, as plain functions of what the provider and the store report.
final class SyncPlannerTests: XCTestCase {
    func testFirstSyncTakesTheNewestAsRecentAndTheRestAsHistory() {
        let plan = SyncPlanner.plan(serverUIDs: [1, 2, 3, 4, 5, 6], known: [], cursor: nil, recentLimit: 2)
        XCTAssertEqual(plan.recent, [6, 5], "newest first")
        XCTAssertEqual(plan.history, [4, 3, 2, 1])
        XCTAssertEqual(plan.gone, [])
        XCTAssertEqual(plan.highestUID, 6)
    }

    func testLaterSyncsTakeEverythingNewAndFindWhatIsGone() {
        let plan = SyncPlanner.plan(serverUIDs: [2, 3, 7, 9, 10], known: [1, 2, 3, 7], cursor: 8, recentLimit: 1)
        XCTAssertEqual(plan.recent, [10, 9], "all new mail, whatever the recent limit")
        XCTAssertEqual(plan.history, [])
        XCTAssertEqual(plan.gone, [1])
        XCTAssertEqual(plan.highestUID, 10)
    }

    func testMissingIsDecidedByWhatIsStoredNeverByTheCursor() {
        // The cursor ran ahead of the writes (it never should; this is the proof that it would
        // not matter): 4 and 5 are below it but not stored, so they are fetched as history.
        let plan = SyncPlanner.plan(serverUIDs: [1, 2, 3, 4, 5], known: [1, 2, 3], cursor: 5, recentLimit: 10)
        XCTAssertEqual(plan.recent, [])
        XCTAssertEqual(plan.history, [5, 4])
    }

    func testAnEmptyFolderKeepsItsCursor() {
        let plan = SyncPlanner.plan(serverUIDs: [], known: [3], cursor: 3, recentLimit: 10)
        XCTAssertEqual(plan.gone, [3])
        XCTAssertEqual(plan.highestUID, 3, "UIDs are never reused within a UIDVALIDITY, so the cursor never goes back")
    }

    func testFoldersAreOrderedInboxFirstAndDisposableLast() {
        func folder(_ id: String, _ role: FolderRole?) -> RemoteFolder {
            RemoteFolder(id: id, path: [id], role: role, isSelectable: true, attributes: [])
        }
        let ordered = SyncPlanner.order([
            folder("Trash", .trash), folder("Projects", nil), folder("Junk", .junk), folder("Sent", .sent),
            folder("Archive", .archive), folder("INBOX", .inbox), folder("Clients", nil), folder("Drafts", .drafts),
        ])
        XCTAssertEqual(ordered.map(\.id), ["INBOX", "Sent", "Drafts", "Archive", "Projects", "Clients", "Junk", "Trash"])
    }

    func testBatchesRespectCountBytesAndTheInMemoryLimit() {
        func summary(_ uid: UInt32, _ size: Int) -> RemoteMessageSummary {
            RemoteMessageSummary(id: RemoteMessageID(folder: "INBOX", uidValidity: 1, uid: uid), flags: MessageFlags(),
                                 size: size, internalDate: nil, messageIDHeader: nil, subject: nil)
        }
        let input = [summary(9, 10), summary(8, 10), summary(7, 10), summary(6, 500), summary(5, 5_000), summary(4, 10)]
        let (batches, tooLarge) = SyncPlanner.batches(input, maxMessages: 2, maxBytes: 600, maxMessageSize: 1_000)
        XCTAssertEqual(batches.map { $0.map(\.id.uid) }, [[9, 8], [7, 6], [4]])
        XCTAssertEqual(tooLarge.map(\.id.uid), [5])

        let (single, _) = SyncPlanner.batches([summary(3, 900), summary(2, 900)], maxMessages: 10, maxBytes: 600, maxMessageSize: 1_000)
        XCTAssertEqual(single.map { $0.map(\.id.uid) }, [[3], [2]], "a message over the byte cap goes alone")
    }

    func testTheBudgetOnlyLimitsWhatItIsGiven() {
        XCTAssertTrue(SyncPlanner.budgetAllows(alreadyImported: 900, next: 100, budget: 1_000))
        XCTAssertFalse(SyncPlanner.budgetAllows(alreadyImported: 901, next: 100, budget: 1_000))
        XCTAssertTrue(SyncPlanner.budgetAllows(alreadyImported: .max / 2, next: 1, budget: nil))
    }

    func testChunks() {
        XCTAssertEqual(SyncPlanner.chunks([1, 2, 3, 4, 5], of: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(SyncPlanner.chunks([Int](), of: 2), [])
    }
}
