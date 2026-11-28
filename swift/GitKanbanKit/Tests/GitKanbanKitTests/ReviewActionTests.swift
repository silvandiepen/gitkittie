import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Review actions, assignment and browser checks end to end over a real folder board: the
/// app model decides, the card files move, and the request records what happened.
@MainActor
final class ReviewActionTests: XCTestCase {
    private var root: URL!

    private static func card(_ id: String, status: String, claimedBy: String? = nil, until: String = "2099-01-01T00:00:00Z") -> String {
        """
        ---
        id: \(id)
        title: Card \(id)
        project: Pets
        status: \(status)
        assignee: claude
        updated_at: 2026-11-20T09:00:00Z
        picked_up_by: \(claimedBy ?? "null")
        claim_expires_at: \(claimedBy == nil ? "null" : until)
        reviewer: null
        review_outcome: null
        review_completed_at: null
        custom_key: keep me
        ---

        # Card \(id)

        ## Activity log

        - 2026-11-20T09:00:00Z — `claude` created the task.
        """
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-actions-\(UUID().uuidString)", isDirectory: true)
        try write("README.md", """
        ---
        config: board
        lanes:
          - { id: todo, name: To do, folder: "1. To do", status: todo }
          - { id: in-progress, name: In Progress, folder: "2. In Progress", status: in-progress }
          - { id: in-review, name: In Review, folder: "3. In Review", status: in-review }
          - { id: testing, name: Testing, folder: "4. Testing", status: testing }
          - { id: done, name: Done, folder: "5. Done", status: done, terminal: true }
        users:
          - { id: sil, name: Sil, kind: human, github: \(NSUserName()) }
          - { id: herma, name: Herma, kind: human }
          - { id: claude, kind: agent }
        ---
        """)
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        for lane in ["1. To do", "2. In Progress", "4. Testing"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Pets/\(lane)"), withIntermediateDirectories: true)
        }
        try write("Pets/3. In Review/PETS-1-site.md", Self.card("PETS-1", status: "in-review", claimedBy: "claude"))
        try write("Pets/3. In Review/PETS-2-badge.md", Self.card("PETS-2", status: "in-review", claimedBy: "herma"))
        try write("Pets/5. Done/PETS-3-old.md", Self.card("PETS-3", status: "done"))
        try write("Pets/review/PETS-1-site/review.md", """
        ---
        config: review
        id: PETS-1-site
        card: PETS-1
        title: Site, round 1
        requested_by: claude
        on_accept: { to: testing }
        on_changes: { to: in-progress, comment: true }
        items:
          - id: hero
            file: hero.png
            status: pending
          - id: badge
            file: badge.png
            status: pending
            on_accept: { move: PETS-2, to: testing }
        ---
        """)
        try write("Pets/review/PETS-1-site/hero.png", "png")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    private func entry() -> AddedRepo {
        AddedRepo(namespace: "folder", name: "Board", branch: "", isPrivate: true,
                  boards: [SelectedBoard(folder: "Pets", name: "Pets")], kind: .localFolder(path: root.path, bookmark: nil))
    }

    private func opened() async -> AppModel {
        let model = AppModel()
        let repo = entry()
        model.addedRepos = [repo]
        await model.openBoard(repo, folder: "Pets")
        return model
    }

    private func request(_ model: AppModel, _ id: String = "PETS-1-site") throws -> ReviewRequest {
        try XCTUnwrap(model.reviews.first { $0.id == id })
    }

    // MARK: Actions

    func testTheLastDecisionMovesTheCardAndRecordsIt() async throws {
        let model = await opened()
        var review = try request(model)
        let ok1 = await model.decide(review, item: review.items[0], status: .approved)
        XCTAssertTrue(ok1)
        XCTAssertTrue(exists("Pets/3. In Review/PETS-1-site.md"), "one item left: no outcome yet")
        review = try request(model)
        // Approving the badge moves PETS-2 (its own action) — claimed by herma, so it waits.
        let ok2 = await model.decide(review, item: review.items[1], status: .approved)
        XCTAssertTrue(ok2)
        XCTAssertNil(model.errorMessage)

        let moved = try read("Pets/4. Testing/PETS-1-site.md")
        XCTAssertFalse(exists("Pets/3. In Review/PETS-1-site.md"))
        XCTAssertTrue(moved.contains("status: testing"))
        XCTAssertTrue(moved.contains("reviewer: sil"))
        XCTAssertTrue(moved.contains("review_outcome: approved"))
        XCTAssertTrue(moved.contains("custom_key: keep me"))
        XCTAssertTrue(moved.contains("picked_up_by: claude"), "claim fields are never touched")
        XCTAssertTrue(moved.contains("`sil` accepted review PETS-1-site; moved to Testing."))

        let report = try XCTUnwrap(model.reviewActionReport)
        XCTAssertEqual(report.outcome, .accept)
        XCTAssertEqual(report.moved.map(\.run.card), ["PETS-1"])
        XCTAssertEqual(report.summary, "Accepted · PETS-1 moved to Testing")
        XCTAssertEqual(report.conflicts.map(\.kind), [.claimed])
        XCTAssertEqual(report.conflicts.first?.message.hasPrefix("PETS-2 is claimed by herma until"), true)
        XCTAssertTrue(exists("Pets/3. In Review/PETS-2-badge.md"), "someone else's claim: skipped")

        let runs = try request(model).actionsRun
        XCTAssertEqual(runs.map(\.result), [.skipped, .moved])
        XCTAssertEqual(runs.map(\.entry), ["badge", nil])
        XCTAssertEqual(runs[1].from, "in-review")
        XCTAssertEqual(runs[1].to, "testing")
        XCTAssertEqual(runs[1].before["reviewer"], .some(nil))

        // Move anyway: the activity line says what was overridden.
        let conflict = try XCTUnwrap(report.conflicts.first)
        let ok3 = await model.moveAnyway(conflict)
        XCTAssertTrue(ok3)
        let badge = try read("Pets/4. Testing/PETS-2-badge.md")
        XCTAssertTrue(badge.contains("moved to Testing although claimed by herma."))
        XCTAssertFalse(badge.contains("reviewer: sil"), "an entry's action does not fill the card's review fields")
        XCTAssertEqual(model.reviewActionReport?.conflicts.isEmpty, true)
        XCTAssertEqual(try request(model).actionsRun.count, 3)

        // Deciding again with the same outcome does not move anything again.
        review = try request(model)
        let ok4 = await model.decide(review, item: review.items[0], status: .approved)
        XCTAssertTrue(ok4)
        XCTAssertEqual(try request(model).actionsRun.count, 3)
    }

    func testUndoTakesTheCardBackWhileNobodyTouchedIt() async throws {
        let model = await opened()
        let review = try request(model)
        let ok5 = await model.decide(review, itemIDs: ["hero", "badge"], status: .changesRequested, comment: "Bigger headline")
        XCTAssertTrue(ok5)
        let moved = try read("Pets/2. In Progress/PETS-1-site.md")
        XCTAssertTrue(moved.contains("review_outcome: changes-requested"))
        XCTAssertTrue(moved.contains("asked for changes in review PETS-1-site; moved to In Progress. Feedback: \"Bigger headline\""))
        let index = try XCTUnwrap(model.reviewActionReport?.moved.first?.index)
        let canUndo = await model.canUndoReviewAction(try request(model).ref, index: index)
        XCTAssertTrue(canUndo)

        let ok6 = await model.undoReviewAction(try request(model).ref, index: index)
        XCTAssertTrue(ok6)
        let back = try read("Pets/3. In Review/PETS-1-site.md")
        XCTAssertFalse(exists("Pets/2. In Progress/PETS-1-site.md"))
        XCTAssertTrue(back.contains("status: in-review"))
        XCTAssertTrue(back.contains("reviewer: null"))
        XCTAssertTrue(back.contains("review_outcome: null"))
        XCTAssertTrue(back.contains("undid the review action of PETS-1-site; moved back to In Review."))
        XCTAssertNotNil(try request(model).actionsRun[index].undoneAt)
        XCTAssertEqual(try request(model).items[0].status, .changesRequested, "the decision stays")
        let again = await model.canUndoReviewAction(try request(model).ref, index: index)
        XCTAssertFalse(again)
    }

    func testUndoIsRefusedOnceSomeoneChangedTheCard() async throws {
        let model = await opened()
        let review = try request(model)
        let ok7 = await model.decide(review, itemIDs: ["hero", "badge"], status: .changesRequested, comment: "No")
        XCTAssertTrue(ok7)
        let index = try XCTUnwrap(model.reviewActionReport?.moved.first?.index)
        let path = "Pets/2. In Progress/PETS-1-site.md"
        try write(path, try read(path).replacingOccurrences(of: "updated_at: ", with: "updated_at: 2027-01-01T00:00:00Z\nold_updated_at: "))
        let canUndo = await model.canUndoReviewAction(try request(model).ref, index: index)
        XCTAssertFalse(canUndo)
        let ok8 = await model.undoReviewAction(try request(model).ref, index: index)
        XCTAssertFalse(ok8)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(exists(path))
    }

    func testAFlippedOutcomeIsOfferedNotRun() async throws {
        let model = await opened()
        var review = try request(model)
        let ok9 = await model.decide(review, itemIDs: ["hero", "badge"], status: .changesRequested, comment: "No")
        XCTAssertTrue(ok9)
        XCTAssertTrue(exists("Pets/2. In Progress/PETS-1-site.md"))
        review = try request(model)
        let ok10 = await model.decide(review, itemIDs: ["hero", "badge"], status: .rejected)
        XCTAssertTrue(ok10)
        // The request has no on_reject: nothing to offer, nothing moved.
        XCTAssertTrue(exists("Pets/2. In Progress/PETS-1-site.md"))
        review = try request(model)
        let ok11 = await model.decide(review, item: review.items[0], status: .approved)
        XCTAssertTrue(ok11)
        let ok12 = await model.decide(try request(model), item: try request(model).items[1], status: .approved)
        XCTAssertTrue(ok12)
        let report = try XCTUnwrap(model.reviewActionReport)
        XCTAssertTrue(report.conflicts.contains { $0.kind == .outcomeChanged && $0.entry == nil && $0.action.to == "testing" })
        XCTAssertTrue(exists("Pets/2. In Progress/PETS-1-site.md"), "a changed outcome only offers its action")
        let offer = try XCTUnwrap(report.conflicts.first { $0.kind == .outcomeChanged && $0.entry == nil })
        let ok13 = await model.moveAnyway(offer)
        XCTAssertTrue(ok13)
        XCTAssertTrue(exists("Pets/4. Testing/PETS-1-site.md"))
    }

    func testACardInDoneIsNotMovedByItself() async throws {
        try write("Pets/review/PETS-3-redo/review.md", """
        ---
        id: PETS-3-redo
        card: PETS-3
        title: Redo
        requested_by: claude
        on_changes: { to: in-progress }
        items:
          - { id: a, file: a.png, status: pending }
        ---
        """)
        let model = await opened()
        let review = try request(model, "PETS-3-redo")
        let ok14 = await model.decide(review, item: review.items[0], status: .changesRequested, comment: "Again")
        XCTAssertTrue(ok14)
        XCTAssertTrue(exists("Pets/5. Done/PETS-3-old.md"))
        XCTAssertEqual(model.reviewActionReport?.conflicts.first?.kind, .terminal)
        XCTAssertEqual(model.reviewActionReport?.conflicts.first?.message, "PETS-3 is already Done.")
    }

    // MARK: Browser checks

    func testACheckCountsTowardTheOutcome() async throws {
        try write("Pets/review/PETS-1-page/review.md", """
        ---
        id: PETS-1-page
        card: PETS-1
        title: Page
        requested_by: claude
        on_accept: { to: testing }
        checks:
          - id: page
            url: https://preview.example.app
            sizes: [phone, desktop]
            checklist:
              - { id: hero, text: Headline fits }
        ---
        """)
        let model = await opened()
        var review = try request(model, "PETS-1-page")
        let check = review.checks[0]
        let ok15 = await model.answerCheck(review, check: check, key: "phone", answers: [("hero", .fail, "Wraps")], viewport: "402x874")
        XCTAssertTrue(ok15)
        let ok16 = await model.saveCheckScreenshot(try request(model, "PETS-1-page"), check: check, key: "phone", png: Data("png".utf8), viewport: "402x874")
        XCTAssertTrue(ok16)
        XCTAssertTrue(exists("Pets/review/PETS-1-page/results/page-phone.png"))
        review = try request(model, "PETS-1-page")
        XCTAssertEqual(review.checks[0].failures.map(\.note), ["Wraps"])
        XCTAssertEqual(review.checks[0].results["phone"]?.screenshot, "results/page-phone.png")
        let ok17 = await model.decideCheck(review, check: review.checks[0], status: .changesRequested)
        XCTAssertFalse(ok17, "changes needs a comment")
        let ok18 = await model.decideCheck(review, check: review.checks[0], status: .approved)
        XCTAssertTrue(ok18)
        XCTAssertTrue(exists("Pets/4. Testing/PETS-1-site.md"))
        XCTAssertEqual(model.reviewActionReport?.outcome, .accept)
    }

    // MARK: Assignment

    func testSomeoneElsesRequestIsReadOnlyAndNotCounted() async throws {
        try write("Pets/review/PETS-1-copy/review.md", """
        ---
        id: PETS-1-copy
        title: Copy
        for: [herma]
        items:
          - { id: copy, file: copy.png, status: pending }
        ---
        """)
        let model = await opened()
        await model.loadReviewInbox()
        let theirs = try request(model, "PETS-1-copy")
        XCTAssertFalse(model.isForMe(theirs))
        XCTAssertEqual(model.readOnlyNotice(theirs), "For Herma. You can comment.")
        let ok19 = await model.decide(theirs, item: theirs.items[0], status: .approved)
        XCTAssertFalse(ok19)
        XCTAssertEqual(model.errorMessage, "For Herma. You can comment.")
        XCTAssertEqual(try request(model, "PETS-1-copy").items[0].status, .pending)
        await model.comment(theirs, item: theirs.items[0], text: "Looks fine to me")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try request(model, "PETS-1-copy").items[0].comments.map(\.text), ["Looks fine to me"])

        XCTAssertEqual(model.pendingReviewCount, 2, "only the request for everyone counts")
        XCTAssertEqual(model.pendingReviewTotal, 2)
        XCTAssertEqual(model.openReviewRequests.map(\.id), ["PETS-1-site"])
        model.reviewAssignmentFilter = .forMe
        XCTAssertEqual(model.shownReviews(model.reviews).map(\.id), ["PETS-1-site"])
        model.reviewAssignmentFilter = .everyone
        XCTAssertEqual(Set(model.shownReviews(model.reviews).map(\.id)), ["PETS-1-site", "PETS-1-copy"])
        model.reviewAssignmentFilter = .forMe
    }

    func testWhoYouAreIsAskedOncePerBoardWhenTheLoginMatchesNobody() async throws {
        try write("README.md", try read("README.md").replacingOccurrences(of: "github: \(NSUserName())", with: "github: someone-else"))
        try write("Pets/review/PETS-1-copy/review.md", """
        ---
        id: PETS-1-copy
        title: Copy
        for: herma
        items:
          - { id: copy, file: copy.png, status: pending }
        ---
        """)
        let model = await opened()
        await model.loadReviewInbox()
        let key = try XCTUnwrap(model.reviewInbox.first?.id)
        XCTAssertTrue(model.needsReviewIdentity(boardKey: key))
        XCTAssertEqual(model.reviewIdentityCandidates(boardKey: key).map(\.id), ["sil", "herma"])
        XCTAssertFalse(model.isForMe(try request(model, "PETS-1-copy")))

        model.setReviewIdentity("herma", boardKey: key)
        defer { model.clearReviewIdentity(boardKey: key) }
        XCTAssertFalse(model.needsReviewIdentity(boardKey: key))
        XCTAssertEqual(model.reviewingAs(boardKey: key), "Herma")
        XCTAssertTrue(model.isForMe(try request(model, "PETS-1-copy")))
        XCTAssertEqual(model.reviewInbox.first?.open.map(\.id).sorted(), ["PETS-1-copy", "PETS-1-site"])
        let copy = try request(model, "PETS-1-copy")
        let ok20 = await model.decide(copy, item: copy.items[0], status: .approved)
        XCTAssertTrue(ok20)
        XCTAssertEqual(try request(model, "PETS-1-copy").items[0].decidedBy, "herma")

        model.setReviewIdentity(nil, boardKey: key)
        XCTAssertFalse(model.needsReviewIdentity(boardKey: key))
        XCTAssertFalse(model.isForMe(try request(model, "PETS-1-copy")), "none of these: requests for everyone only")
    }
}
