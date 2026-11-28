import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// The rules every review screen keeps when deciding (Changes needs a comment), the earlier
/// comments a request offers to reuse, picking one option, Undo, and the full-screen viewer's
/// pager. Decisions go through the app model onto a real temporary folder board.
@MainActor
final class ReviewDecisionTests: XCTestCase {
    private var root: URL!
    private var board: URL!
    private var suite: String!
    private let path = "Tasks/Mail/review/MAIL-1-icons/review.md"

    private let reviewText = """
    ---
    config: review
    id: MAIL-1-icons
    title: Icons
    requested_by: claude
    items:
      - id: icon-a
        file: a.png
        group: icons
        status: approved
        decided_by: sil
        decided_at: 2026-11-20T10:00:00Z
        comments:
          - by: sil
            at: 2026-11-20T10:00:00Z
            text: Thinner lines
          - by: claude
            at: 2026-11-20T11:00:00Z
            text: Done in round 2
      - id: icon-b
        file: b.png
        group: icons
        status: changes-requested
        decided_by: sil
        decided_at: 2026-11-21T09:00:00Z
        comments:
          - by: sil
            at: 2026-11-21T09:00:00Z
            text: "  Make the background darker "
          - by: sil
            at: 2026-11-21T09:05:00Z
            text: See the marked-up image.
            image: annotations/icon-b.png
      - id: icon-c
        file: c.png
        group: icons
        status: pending
        comments:
          - by: sil
            at: 2026-11-22T08:00:00Z
            text: make the background DARKER
      - id: icon-d
        file: d.png
        status: pending
        comments: []
      - id: dog-v1
        file: dog-v1.png
        group: dog
        pick: one
        status: approved
        decided_by: sil
        decided_at: 2026-11-20T10:00:00Z
        comments: []
      - id: dog-v2
        file: dog-v2.png
        group: dog
        pick: one
        status: pending
        comments: []
      - id: dog-v3
        file: dog-v3.png
        group: dog
        pick: one
        status: rejected
        decided_by: sil
        decided_at: 2026-11-20T10:00:00Z
        comments: []
    questions:
      - id: order
        question: Which first?
        select: one
        options: [icons, dogs]
        comments:
          - by: sil
            at: 2026-11-19T10:00:00Z
            text: Icons, they block the release
    ---
    """

    override func setUp() async throws {
        suite = "rev2-review-decisions-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        board = root.appendingPathComponent("Board", isDirectory: true)
        try write("Tasks/README.md", """
        ---
        config: board
        review_path: review
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
        users:
          - id: sil
            github: \(NSUserName())
        ---
        """)
        try write("Tasks/Mail/README.md", "---\nconfig: project\nproject: Mail\nlanes: []\n---\n")
        try FileManager.default.createDirectory(at: board.appendingPathComponent("Tasks/Mail/1. To do"), withIntermediateDirectories: true)
        try write(path, reviewText)
    }

    override func tearDown() async throws {
        AppModel.removeTestStorage(suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = board.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func onDisk() throws -> ReviewRequest {
        Review.parse(try String(contentsOf: board.appendingPathComponent(path), encoding: .utf8), folder: "f")
    }

    private func open() async throws -> AppModel {
        let model = AppModel.testing(suite: suite, keychainService: suite)
        let entry = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                              boards: [SelectedBoard(folder: "Tasks/Mail", name: "Mail")],
                              kind: .localFolder(path: board.path, bookmark: nil))
        await model.openBoard(entry, folder: "Tasks/Mail")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.reviews.map(\.id), ["MAIL-1-icons"])
        return model
    }

    private func request(_ model: AppModel) throws -> ReviewRequest { try XCTUnwrap(model.reviews.first) }
    private func item(_ request: ReviewRequest, _ id: String) throws -> ReviewItem { try XCTUnwrap(request.items.first { $0.id == id }) }

    // MARK: Changes needs a comment

    func testTheRule() {
        XCTAssertTrue(ReviewStatus.changesRequested.needsComment)
        XCTAssertFalse(ReviewStatus.approved.needsComment)
        XCTAssertFalse(ReviewStatus.rejected.needsComment)
        XCTAssertFalse(ReviewStatus.pending.needsComment)
        XCTAssertFalse(ReviewDecisionRule.canSend(.changesRequested, comment: nil))
        XCTAssertFalse(ReviewDecisionRule.canSend(.changesRequested, comment: "  \n "))
        XCTAssertTrue(ReviewDecisionRule.canSend(.changesRequested, comment: "Darker"))
        XCTAssertTrue(ReviewDecisionRule.canSend(.approved, comment: nil))
        XCTAssertTrue(ReviewDecisionRule.canSend(.rejected, comment: ""))
    }

    func testChangesWithoutACommentIsRefusedAndNothingIsWritten() async throws {
        let model = try await open()
        let before = try String(contentsOf: board.appendingPathComponent(path), encoding: .utf8)
        let refused = await model.decide(try request(model), item: try item(try request(model), "icon-d"), status: .changesRequested)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, ReviewDecisionRule.commentRequired)
        let blank = await model.decide(try request(model), item: try item(try request(model), "icon-d"), status: .changesRequested, comment: "   ")
        XCTAssertFalse(blank)
        XCTAssertEqual(try String(contentsOf: board.appendingPathComponent(path), encoding: .utf8), before, "the file is untouched")
    }

    func testChangesWithACommentWritesBothInOneGo() async throws {
        let model = try await open()
        let written = await model.decide(try request(model), item: try item(try request(model), "icon-d"),
                                         status: .changesRequested, comment: "  Rounder corners ")
        XCTAssertTrue(written)
        XCTAssertNil(model.errorMessage)
        let d = try item(try onDisk(), "icon-d")
        XCTAssertEqual(d.status, .changesRequested)
        XCTAssertEqual(d.comments.map(\.text), ["Rounder corners"])
        XCTAssertEqual(d.comments.first?.at, d.decidedAt, "the comment and the decision carry the same time")
        XCTAssertEqual(d.decidedBy, "sil")
    }

    func testApproveAndRejectNeedNoComment() async throws {
        let model = try await open()
        let approved = await model.decide(try request(model), item: try item(try request(model), "icon-d"), status: .approved)
        XCTAssertTrue(approved)
        let rejected = await model.decide(try request(model), item: try item(try request(model), "icon-c"), status: .rejected)
        XCTAssertTrue(rejected)
        let onDisk = try onDisk()
        XCTAssertEqual(try item(onDisk, "icon-d").status, .approved)
        XCTAssertEqual(try item(onDisk, "icon-d").comments, [])
        XCTAssertEqual(try item(onDisk, "icon-c").status, .rejected)
    }

    func testBulkChangesNeedsOneCommentThatEveryChosenFileGets() async throws {
        let model = try await open()
        let refused = await model.decide(try request(model), itemIDs: ["icon-c", "icon-d"], status: .changesRequested)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, ReviewDecisionRule.commentRequired)
        XCTAssertEqual(try item(try onDisk(), "icon-c").status, .pending)

        // icon-b already asks for changes: it keeps its decision and gets the comment too.
        let written = await model.decide(try request(model), itemIDs: ["icon-b", "icon-c", "icon-d"], status: .changesRequested,
                                         comment: "Use the new palette")
        XCTAssertTrue(written)
        let onDisk = try onDisk()
        for id in ["icon-b", "icon-c", "icon-d"] {
            XCTAssertEqual(try item(onDisk, id).status, .changesRequested)
            XCTAssertEqual(try item(onDisk, id).comments.last?.text, "Use the new palette", id)
        }
        XCTAssertEqual(try item(onDisk, "icon-b").decidedAt, "2026-11-21T09:00:00Z", "a file that had the decision keeps its time")
    }

    func testChangesOnEveryWaitingFileNeedsAComment() async throws {
        let model = try await open()
        let refused = await model.decideAll(try request(model), status: .changesRequested)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, ReviewDecisionRule.commentRequired)
        let written = await model.decideAll(try request(model), status: .changesRequested, comment: "Again, smaller")
        XCTAssertTrue(written)
        let onDisk = try onDisk()
        XCTAssertEqual(onDisk.items.filter { $0.comments.last?.text == "Again, smaller" }.map(\.id), ["icon-c", "icon-d", "dog-v2"])
        XCTAssertEqual(onDisk.items.map(\.status), [.approved, .changesRequested, .changesRequested, .changesRequested, .approved, .changesRequested, .rejected])
    }

    // MARK: Earlier comments to reuse

    func testSuggestionsAreTheRequestsCommentsNewestFirstOnceEach() throws {
        let request = Review.parse(reviewText, folder: "f")
        // "make the background DARKER" (22nd) is newer than "Make the background darker" (21st):
        // the same text once, as last written. The agent's comment and the one with a marked-up
        // image are left out; question comments count.
        XCTAssertEqual(request.commentSuggestions(),
                       ["make the background DARKER", "Thinner lines", "Icons, they block the release"])
        XCTAssertEqual(request.commentSuggestions(limit: 2), ["make the background DARKER", "Thinner lines"])
    }

    func testSuggestionsLeaveOutWhatTheFileAlreadySays() throws {
        let request = Review.parse(reviewText, folder: "f")
        let c = try item(request, "icon-c")
        XCTAssertEqual(request.commentSuggestions(excluding: c), ["Thinner lines", "Icons, they block the release"])
        XCTAssertEqual(Review.parse("---\nconfig: review\nid: x\ntitle: X\nitems: []\n---\n", folder: "f").commentSuggestions(), [])
    }

    func testSuggestionsWithoutTimesFollowTheFileOrderLatestFirst() {
        let request = Review.parse("""
        ---
        config: review
        id: x
        title: X
        items:
          - id: a
            file: a.png
            status: pending
            comments:
              - by: sil
                at: someday
                text: First
              - by: sil
                at: someday
                text: Second
        ---
        """, folder: "f")
        XCTAssertEqual(request.commentSuggestions(), ["Second", "First"])
    }

    // MARK: Pick one and Undo

    func testPickingAnOptionRejectsTheOthersInOneWriteAndUndoPutsThemBack() async throws {
        let model = try await open()
        let before = try request(model)
        let picked = await model.pick(before, item: try item(before, "dog-v2"))
        XCTAssertTrue(picked)
        let after = try onDisk()
        XCTAssertEqual(after.items.suffix(3).map(\.status), [.rejected, .approved, .rejected], "the earlier pick is rejected, the new one approved")

        let undo = try XCTUnwrap(ReviewUndo(ref: before.ref, itemID: "dog-v2", status: .approved, before: before, after: try request(model)))
        XCTAssertEqual(undo.previous, ["dog-v1": .approved, "dog-v2": .pending])
        XCTAssertEqual(undo.message, "Approved dog-v2")
        let undone = await model.undo(undo)
        XCTAssertTrue(undone)
        XCTAssertEqual(try onDisk().items.suffix(3).map(\.status), [.approved, .pending, .rejected])
    }

    func testUndoOfAChangeKeepsTheCommentAndUndoBackToChangesNeedsNone() async throws {
        let model = try await open()
        let before = try request(model)
        await model.decide(before, item: try item(before, "icon-b"), status: .rejected)
        let undo = try XCTUnwrap(ReviewUndo(ref: before.ref, itemID: "icon-b", status: .rejected, before: before, after: try request(model)))
        XCTAssertEqual(undo.previous, ["icon-b": .changesRequested])
        let undone = await model.undo(undo)
        XCTAssertTrue(undone, "back to Changes: the comment it was asked with is still there")
        XCTAssertNil(model.errorMessage)
        let b = try item(try onDisk(), "icon-b")
        XCTAssertEqual(b.status, .changesRequested)
        XCTAssertEqual(b.comments.count, 2)
        XCTAssertNil(ReviewUndo(ref: before.ref, itemID: "icon-b", status: .approved, before: before, after: before), "nothing changed, nothing to undo")
    }

    // MARK: The full-screen pager

    func testThePagerHoldsWhatTheFilterShowsAndGoesToTheNextWaitingFile() throws {
        let request = Review.parse(reviewText, folder: "f")
        // Waiting: pending items, with the options of the still-open pick-one group (dog-v1 and
        // dog-v3 stay with dog-v2); the decided icons are left out.
        let waiting = ReviewPager(request: request, filter: .waiting)
        XCTAssertEqual(waiting.itemIDs, ["icon-c", "icon-d", "dog-v1", "dog-v2", "dog-v3"])
        XCTAssertEqual(ReviewPager(request: request, filter: .answered).itemIDs, ["icon-a", "icon-b", "dog-v1", "dog-v3"])
        XCTAssertEqual(ReviewPager(request: request, filter: .all).itemIDs, request.items.map(\.id))

        XCTAssertEqual(waiting.positionLabel(of: "icon-d", in: request), "2 of 5")
        XCTAssertEqual(waiting.waitingCount(in: request), 3)
        XCTAssertEqual(waiting.marks(in: request), [.pending, .pending, .approved, .pending, .rejected])
        XCTAssertEqual(waiting.nextWaiting(after: "icon-d", in: request), "dog-v2", "skips the decided options")
        XCTAssertEqual(waiting.nextWaiting(after: "dog-v2", in: request), "icon-c", "wraps round to the start")
        XCTAssertEqual(waiting.nextWaiting(after: nil, in: request), "icon-c")
        XCTAssertEqual(waiting.start(at: "dog-v1", in: request), "dog-v1", "starts at the tapped file")
        XCTAssertEqual(waiting.start(at: "icon-a", in: request), "icon-c", "a file not on show starts at the first that waits")
    }

    func testThePagerKeepsItsPagesAsFilesAreDecided() async throws {
        let model = try await open()
        let pager = ReviewPager(request: try request(model), filter: .waiting)
        await model.decide(try request(model), item: try item(try request(model), "icon-c"), status: .approved)
        let now = try request(model)
        XCTAssertEqual(pager.items(in: now).map(\.id), ["icon-c", "icon-d", "dog-v1", "dog-v2", "dog-v3"], "the decided file stays a page")
        XCTAssertEqual(pager.items(in: now).first?.status, .approved, "in its new state")
        XCTAssertEqual(pager.nextWaiting(after: "icon-c", in: now), "icon-d")
        await model.decide(now, item: try item(now, "icon-d"), status: .rejected)
        await model.decide(try request(model), item: try item(try request(model), "dog-v2"), status: .rejected)
        XCTAssertNil(pager.nextWaiting(after: "dog-v2", in: try request(model)), "nothing else waits")
        XCTAssertEqual(pager.waitingCount(in: try request(model)), 0)
    }
}
