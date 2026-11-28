import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// The review tools' new parts over a real folder board: browser checks, actions, `for`, `due`,
/// the cleanup that waits for checks, and fetching a request's file.
@MainActor
final class AgentReviewCheckTests: XCTestCase {
    private var root: URL!
    private var board: AgentBoard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-agent-check-\(UUID().uuidString)", isDirectory: true)
        try write("README.md", """
        ---
        config: board
        lanes:
          - { id: todo, name: To do, folder: "1. To do", status: todo }
          - { id: testing, name: Testing, folder: "4. Testing", status: testing }
        users:
          - { id: sil, kind: human }
          - { id: claude, kind: agent }
        ---
        """)
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        try write("Pets/1. To do/PETS-001-site.md", CardText.make(id: "PETS-001", title: "Site", project: "Pets", status: "todo"))
        board = AgentBoard(source: LocalFolderSource(root: root, securityScoped: false), folder: "Pets")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    private func check(_ id: String = "page", url: String = "https://preview.example.app/onboarding") throws -> Review.NewCheck {
        try AppModel.agentCheck([
            "id": id, "url": url, "title": "Onboarding",
            "sizes": ["phone", "1080x1920", ["id": "kiosk", "width": 1080, "height": 1920, "ua": "desktop"]],
            "appearance": ["light", "dark", "light"],
            "checklist": ["The headline fits", ["id": "cta", "text": "Download shows"]],
            "on_accept": ["move": "PETS-001", "to": "testing"],
        ])
    }

    private func expectRefusal(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected a refusal containing \(message)", file: file, line: line)
        } catch let error as AgentBoardError {
            XCTAssertTrue(error.message.contains(message), error.message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testAgentCheckReadsTheToolsJSON() throws {
        let made = try check()
        XCTAssertEqual(made.sizes.map(\.id), ["phone", "1080x1920", "kiosk"])
        XCTAssertEqual(made.sizes[2], CheckSize(id: "kiosk", label: "kiosk", width: 1080, height: 1920, ua: .desktop))
        XCTAssertEqual(made.appearance, [.light, .dark])
        XCTAssertEqual(made.checklist, [CheckLine(id: "the-headline-fits", text: "The headline fits"), CheckLine(id: "cta", text: "Download shows")])
        XCTAssertEqual(made.actions.accept, [ReviewAction(move: "PETS-001", to: "testing")])
        XCTAssertThrowsError(try AppModel.agentCheck(["id": "x", "url": "https://x.example", "sizes": ["huge"], "checklist": ["a"]]))
        let options = try XCTUnwrap(AppModel.agentRequestOptions(["for": "sil", "due": "2026-12-02",
                                                                  "on_changes": [["to": "todo", "comment": true]]]))
        XCTAssertEqual(options, Review.RequestOptions(assignedTo: ["sil"], due: "2026-12-02",
                                                      actions: ReviewActions(changes: [ReviewAction(to: "todo", comment: true)])))
        XCTAssertNil(try AppModel.agentRequestOptions([:]))
        XCTAssertThrowsError(try AppModel.agentRequestOptions(["on_accept": ["comment": true]]))
    }

    func testACheckIsCreatedListedAndKeepsTheRequestUntilDecided() async throws {
        let made = try await board.createReview(
            request: nil, card: "PETS-001", title: "Onboarding page", question: nil, notes: nil, uploads: [],
            checks: [try check()], options: Review.RequestOptions(assignedTo: ["sil"], due: "2026-12-02",
                                                                actions: ReviewActions(accept: [ReviewAction(to: "testing")])),
            agent: "claude")
        XCTAssertEqual(made["checks"] as? [String], ["page"])
        XCTAssertEqual(made["for"] as? [String], ["sil"])
        XCTAssertNil(made["warnings"])
        let file = "Pets/review/PETS-001-onboarding-page/review.md"
        let review = Review.parse(try read(file), folder: "x")
        XCTAssertEqual(review.assignedTo, ["sil"])
        XCTAssertEqual(review.due, "2026-12-02")
        XCTAssertEqual(review.actions.accept, [ReviewAction(to: "testing")])
        XCTAssertTrue(review.items.isEmpty)
        XCTAssertEqual(review.checks.first?.resultKeys.count, 6)

        var listed = try await board.listReviews(state: "pending", card: nil, forUser: "sil")
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["for"] as? [String], ["sil"])
        XCTAssertTrue(listed.first?["outcome"] is NSNull)
        XCTAssertEqual((listed.first?["on_accept"] as? [[String: Any]])?.first?["to"] as? String, "testing")
        let forClaude = try await board.listReviews(state: "pending", card: nil, forUser: "claude")
        XCTAssertEqual(forClaude.count, 0)

        // The reviewer answers and decides, as the app does.
        var text = try read(file)
        text = try Review.applyCheckAnswer(text, checkID: "page", key: "phone.light", line: "cta", result: .fail, note: "Below the fold", by: "sil")
        text = try Review.applyCheckScreenshot(text, checkID: "page", key: "phone.light", path: "results/page-phone.light.png", by: "sil")
        text = try Review.applyCheckDecision(text, checkID: "page", status: .changesRequested, by: "sil")
        try write(file, text)
        try write("Pets/review/PETS-001-onboarding-page/results/page-phone.light.png", "png-bytes")

        listed = try await board.listReviews(state: nil, card: "PETS-001")
        let listedCheck = try XCTUnwrap((listed.first?["checks"] as? [[String: Any]])?.first)
        XCTAssertEqual(listedCheck["status"] as? String, "changes-requested")
        XCTAssertEqual((listedCheck["failed"] as? [[String: Any]])?.first?["note"] as? String, "Below the fold")
        XCTAssertEqual((listedCheck["failed"] as? [[String: Any]])?.first?["screenshot"] as? String, "results/page-phone.light.png")
        XCTAssertEqual(listed.first?["outcome"] as? String, "changes")

        let fetched = try await board.reviewFile(request: "PETS-001-onboarding-page", path: "results/page-phone.light.png")
        XCTAssertEqual(fetched["content_base64"] as? String, Data("png-bytes".utf8).base64EncodedString())
        await expectRefusal("not a file inside") { _ = try await self.board.reviewFile(request: "PETS-001-onboarding-page", path: "../../README.md") }
        await expectRefusal("has no file") { _ = try await self.board.reviewFile(request: "PETS-001-onboarding-page", path: "nope.png") }

        // Handled, the request is finished and goes.
        let handled = try await board.handleReviewItem(request: "PETS-001-onboarding-page", item: "page", shippedTo: nil, keep: false)
        XCTAssertNotNil(handled["closed"])
        XCTAssertFalse(exists(file))
    }

    func testHandlingTheLastItemLeavesARequestWithAnUndecidedCheck() async throws {
        let made = try await board.createReview(
            request: nil, card: nil, title: "Mixed", question: nil, notes: nil,
            uploads: [AgentBoard.ReviewUpload(item: Review.NewItem(id: "shot", file: "shot.png"), data: Data("png".utf8))],
            checks: [try check()], agent: "claude")
        let file = "Pets/review/\(made["request"] as! String)/review.md"
        try write(file, try Review.applyDecision(try read(file), itemID: "shot", status: .approved, by: "sil"))
        let handled = try await board.handleReviewItem(request: made["request"] as! String, item: "shot", shippedTo: nil, keep: false)
        XCTAssertEqual(handled["pending"] as? Int, 1)
        XCTAssertNil(handled["closed"])
        XCTAssertTrue(exists(file), "a check still waits: the request stays")
        await expectRefusal("Waiting for the reviewer: page") { _ = try await self.board.closeReview(request: made["request"] as! String, force: false) }
    }

    func testRefusesWhatCannotWork() async throws {
        func create(_ checks: [Review.NewCheck] = [], questions: [Review.NewQuestion] = [], card: String? = "PETS-001",
                    options: Review.RequestOptions? = nil) async throws {
            _ = try await board.createReview(request: nil, card: card, title: "T", question: nil, notes: nil, uploads: [],
                                             questions: questions, checks: checks, options: options, agent: "claude")
        }
        await expectRefusal("No lane \"review\"") {
            try await create([try self.check()], options: Review.RequestOptions(actions: ReviewActions(accept: [ReviewAction(to: "review")])))
        }
        await expectRefusal("\"for\": herma is not a user") {
            try await create([try self.check()], options: Review.RequestOptions(assignedTo: ["herma"]))
        }
        await expectRefusal("only questions never has an outcome") {
            try await create(questions: [Review.NewQuestion(id: "q", question: "Q?", options: [ReviewQuestionOption(id: "a", label: "A")])],
                             options: Review.RequestOptions(actions: ReviewActions(accept: [ReviewAction(to: "testing")])))
        }
        await expectRefusal("the request has no \"card\"") {
            try await create([try self.check()], card: nil, options: Review.RequestOptions(actions: ReviewActions(accept: [ReviewAction(to: "testing")])))
        }
        await expectRefusal("needs \"move\"") {
            var bad = try self.check()
            bad.actions = ReviewActions(accept: [ReviewAction(to: "testing")])
            try await create([bad])
        }
        await expectRefusal("http or https") { try await create([try self.check(url: "file:///etc/hosts")]) }
        await expectRefusal("\"due\" is a day") { try await create([try self.check()], options: Review.RequestOptions(due: "Friday")) }
        await expectRefusal("needs a checklist") {
            try await create([Review.NewCheck(id: "c", url: "https://x.example", checklist: [])])
        }
        await expectRefusal("No card \"PETS-404\"") {
            var bad = try self.check()
            bad.actions = ReviewActions(accept: [ReviewAction(move: "PETS-404", to: "testing")])
            try await create([bad])
        }
        XCTAssertFalse(exists("Pets/review"), "nothing was written")

        let local = try await board.createReview(request: nil, card: nil, title: "Local", question: nil, notes: nil, uploads: [],
                                                 checks: [try check(url: "http://localhost:5173/")], agent: "claude")
        XCTAssertEqual((local["warnings"] as? [String])?.count, 1)
    }
}
