import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// A refused write whose content is not on this device (Sil's ARVIK-471, GITKITTIE-111) can
/// never be sent. It is told apart from one a retry can still send, Retry All leaves it alone,
/// and it can be removed.
@MainActor
final class UnsendableSyncTests: XCTestCase {
    private let suite = "gk-unsendable-\(UUID().uuidString)"

    override func tearDown() async throws {
        AppModel.removeTestStorage(suite)
    }

    private func operation(_ id: String, path: String) -> OutboxOperation {
        OutboxOperation(id: id, repoKey: "someone/board", kind: .write, path: path, message: "Change \(id)",
                        createdAt: Date(), state: .failed, note: "Refused", attempts: 1, review: nil)
    }

    func testAWriteWithoutContentIsUnsendableAndRetryAllLeavesItForRemoval() async throws {
        let model = AppModel.testing(suite: suite, keychainService: suite)
        let directory = AppModel.testStorage(suite).appendingPathComponent("Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = operation("stale", path: "Arvik/review/ARVIK-471-unit-reply-timing/review.md")
        let card = operation("card", path: "Arvik/1. To do/ARVIK-001-a.md")
        try JSONEncoder().encode([stale, card]).write(to: directory.appendingPathComponent("outbox.json"))
        // The card's change is on this device; the review request's is not.
        try Data("---\nid: ARVIK-001\n---\n".utf8).write(to: directory.appendingPathComponent("card.blob"))

        await model.refreshSyncItems()
        XCTAssertEqual(model.failedSyncItems.map(\.id), ["stale", "card"])
        XCTAssertEqual(model.unsendableSyncIDs, ["stale"])
        XCTAssertTrue(model.isUnsendable(stale))
        XCTAssertEqual(model.retryableFailedSyncItems.map(\.id), ["card"])

        await model.retryAllFailedSync()
        let states = Dictionary(uniqueKeysWithValues: model.syncItems.map { ($0.id, $0.state) })
        XCTAssertEqual(states["stale"], .failed, "a write that cannot be sent is not sent again")
        XCTAssertEqual(states["card"], .pending, "the other one is retried (no connection here, so it waits)")

        await model.discardSync(stale)
        XCTAssertEqual(model.syncItems.map(\.id), ["card"])
        XCTAssertTrue(model.unsendableSyncIDs.isEmpty)
    }

    func testADeletionAlwaysHasWhatItNeeds() async throws {
        let outbox = Outbox(directory: AppModel.testStorage(suite).appendingPathComponent("Outbox", isDirectory: true))
        var deletion = operation("gone", path: "Arvik/1. To do/ARVIK-002-b.md")
        deletion.kind = .delete
        let canSend = await outbox.canSend(deletion)
        XCTAssertTrue(canSend)
    }
}
