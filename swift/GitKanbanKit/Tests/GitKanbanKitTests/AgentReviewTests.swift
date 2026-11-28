import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// The review tools an agent gets, end-to-end over a real temp folder: ask for a review,
/// see the reviewer's decisions, record them as handled, and have the finished request
/// cleared away.
@MainActor
final class AgentReviewTests: XCTestCase {
    private var root: URL!
    private var board: AgentBoard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-agent-review-\(UUID().uuidString)", isDirectory: true)
        try write("README.md", "---\nconfig: board\nreview_path: \"review\"\nlanes:\n  - id: todo\n    name: To do\n    folder: \"1. To do\"\n    status: todo\n---\n")
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        try write("Pets/1. To do/PETS-001-dogs.md", CardText.make(id: "PETS-001", title: "Dogs", project: "Pets", status: "todo"))
        board = AgentBoard(source: LocalFolderSource(root: root, securityScoped: false), folder: "Pets")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    private func upload(_ id: String, revises: String? = nil) -> AgentBoard.ReviewUpload {
        AgentBoard.ReviewUpload(item: Review.NewItem(id: id, file: "\(id).png", note: "A \(id)", revises: revises), data: Data("png-\(id)".utf8))
    }

    func testNotifyLevelIsWrittenAndCanBeChangedLater() async throws {
        let made = try await board.createReview(request: nil, card: nil, title: "Blocked", question: nil, notes: nil,
                                                uploads: [upload("a")], notify: .urgent, agent: "claude")
        XCTAssertEqual(made["notify"] as? String, "urgent")
        let file = "Pets/review/blocked/review.md"
        var text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        XCTAssertEqual(Review.parse(text, folder: "Pets/review/blocked").notify, .urgent)
        let listed = try await board.listReviews(state: "pending", card: nil)
        XCTAssertEqual(listed.first?["notify"] as? String, "urgent")

        // Only the level, on an existing request.
        _ = try await board.createReview(request: "blocked", card: nil, title: nil, question: nil, notes: nil,
                                         uploads: [], notify: .silent, agent: "claude")
        text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        XCTAssertEqual(Review.parse(text, folder: "Pets/review/blocked").notify, .silent)
        XCTAssertEqual(Review.parse(text, folder: "Pets/review/blocked").items.map(\.id), ["a"])
    }

    func testRequestDecideHandleAndAutomaticCleanup() async throws {
        let made = try await board.createReview(request: nil, card: "PETS-001", title: "Dog models", question: "Which dog?",
                                                notes: "First pass.", uploads: [upload("dog-v1"), upload("dog-v2")], agent: "claude")
        XCTAssertEqual(made["request"] as? String, "PETS-001-dog-models")
        XCTAssertTrue(exists("Pets/review/PETS-001-dog-models/dog-v1.png"))

        // Nothing is decided yet: nothing to handle, two items pending.
        var toHandle = try await board.listReviews(state: nil, card: nil)
        XCTAssertTrue(toHandle.isEmpty)
        let pending = try await board.listReviews(state: "pending", card: "PETS-001")
        XCTAssertEqual(pending.first?["pending"] as? Int, 2)
        do {
            _ = try await board.handleReviewItem(request: "PETS-001-dog-models", item: "dog-v1", shippedTo: nil, keep: false)
            XCTFail("an undecided item cannot be handled")
        } catch is AgentBoardError {}

        // The reviewer decides, as the app does.
        let file = "Pets/review/PETS-001-dog-models/review.md"
        var text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        text = try Review.applyDecision(text, itemID: "dog-v1", status: .approved, by: "sil")
        text = try Review.applyDecision(text, itemID: "dog-v2", status: .changesRequested, by: "sil")
        text = try Review.appendComment(text, itemID: "dog-v2", by: "sil", body: "Longer ears")
        try write(file, text)

        toHandle = try await board.waitForReviews(card: nil, timeout: 5, interval: 1)
        let items = try XCTUnwrap(toHandle.first?["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String }, ["dog-v1", "dog-v2"])
        XCTAssertEqual(((items[1]["comments"] as? [[String: Any]])?.first?["text"]) as? String, "Longer ears")

        // A request with decisions waiting cannot be closed by accident.
        do { _ = try await board.closeReview(request: "PETS-001-dog-models", force: false); XCTFail("not finished") } catch is AgentBoardError {}

        // The redo joins the same request; the old item is handled.
        _ = try await board.createReview(request: "PETS-001-dog-models", card: nil, title: nil, question: nil, notes: nil,
                                         uploads: [upload("dog-v3", revises: "dog-v2")], agent: "claude")
        var result = try await board.handleReviewItem(request: "PETS-001-dog-models", item: "dog-v2", shippedTo: nil, keep: false)
        XCTAssertEqual(result["pending"] as? Int, 1)
        XCTAssertNil(result["closed"], "the redo is still waiting, so the request stays")
        result = try await board.handleReviewItem(request: "PETS-001-dog-models", item: "dog-v1", shippedTo: "content/dog.png", keep: false)
        XCTAssertNil(result["closed"])
        let parsed = Review.parse(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8), folder: "f")
        XCTAssertEqual(parsed.items.first { $0.id == "dog-v1" }?.shippedTo, "content/dog.png")
        XCTAssertEqual(parsed.items.first { $0.id == "dog-v1" }?.decidedBy, "sil", "the reviewer's fields are untouched")
        XCTAssertEqual(parsed.items.first { $0.id == "dog-v3" }?.revises, "dog-v2")

        // The redo is approved and handled: nothing is left, so the request is cleared away.
        try write(file, try Review.applyDecision(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8), itemID: "dog-v3", status: .approved, by: "sil"))
        result = try await board.handleReviewItem(request: "PETS-001-dog-models", item: "dog-v3", shippedTo: "content/dog.png", keep: false)
        XCTAssertEqual(result["closed"] as? Int, 4, "three assets and the request file")
        XCTAssertFalse(exists("Pets/review/PETS-001-dog-models/review.md"))
        XCTAssertFalse(exists("Pets/review/PETS-001-dog-models/dog-v1.png"))
        let all = try await board.listReviews(state: "all", card: nil)
        XCTAssertTrue(all.isEmpty)
    }

    func testWaitReturnsEmptyWhenNothingIsDecidedAndKeepLeavesAFinishedRequest() async throws {
        _ = try await board.createReview(request: nil, card: nil, title: "Icons", question: nil, notes: nil, uploads: [upload("a")], agent: "claude")
        let waited = try await board.waitForReviews(card: nil, timeout: 1, interval: 1)
        XCTAssertTrue(waited.isEmpty)
        let file = "Pets/review/icons/review.md"
        try write(file, try Review.applyDecision(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8), itemID: "a", status: .rejected, by: "sil"))
        let result = try await board.handleReviewItem(request: "icons", item: "a", shippedTo: nil, keep: true)
        XCTAssertEqual(result["finished"] as? Bool, true)
        XCTAssertTrue(exists(file))
        let closed = try await board.closeReview(request: "icons", force: false)
        XCTAssertEqual(closed["closed"] as? Int, 2)
        XCTAssertFalse(exists(file))
        // A request for a card that does not exist is refused before anything is written.
        do {
            _ = try await board.createReview(request: nil, card: "PETS-999", title: "X", question: nil, notes: nil, uploads: [upload("b")], agent: "claude")
            XCTFail("unknown card")
        } catch is AgentBoardError {}
        XCTAssertFalse(exists("Pets/review/PETS-999-x"))
    }

    private func providers(id: String = "providers") -> Review.NewQuestion {
        Review.NewQuestion(id: id, question: "Which providers at first release?", detail: "Gmail needs **verification**.",
                           select: .one, allowsOther: true,
                           options: [ReviewQuestionOption(id: "icloud", label: "iCloud only", detail: "Smallest scope."),
                                     ReviewQuestionOption(id: "imap", label: "iCloud and IMAP")])
    }

    func testQuestionsAreAskedAnsweredAndHandled() async throws {
        let platforms = Review.NewQuestion(id: "platforms", question: "Where?", select: .many,
                                           options: [ReviewQuestionOption(id: "mac", label: "Mac"), ReviewQuestionOption(id: "ios", label: "iPhone")])
        let made = try await board.createReview(request: nil, card: "PETS-001", title: "Mail decisions", question: nil, notes: nil,
                                                uploads: [], questions: [providers(), platforms], agent: "claude")
        XCTAssertEqual(made["questions"] as? [String], ["providers", "platforms"])
        let file = "Pets/review/PETS-001-mail-decisions/review.md"
        XCTAssertTrue(exists(file))

        // Unanswered questions wait for the reviewer and cannot be handled.
        let pending = try await board.listReviews(state: "pending", card: nil)
        XCTAssertEqual(pending.first?["pending"] as? Int, 2)
        let listed = try XCTUnwrap(pending.first?["questions"] as? [[String: Any]])
        XCTAssertEqual(listed.first?["select"] as? String, "one")
        XCTAssertEqual(listed.first?["status"] as? String, "pending")
        XCTAssertEqual((listed.first?["options"] as? [[String: Any]])?.first?["detail"] as? String, "Smallest scope.")
        XCTAssertNil(listed.first?["answer"])
        let nothing = try await board.listReviews(state: nil, card: nil)
        XCTAssertTrue(nothing.isEmpty)
        do {
            _ = try await board.handleReviewItem(request: "PETS-001-mail-decisions", item: "providers", shippedTo: nil, keep: false)
            XCTFail("an unanswered question cannot be handled")
        } catch is AgentBoardError {}

        // The reviewer answers one, as the app does.
        var text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        text = try Review.applyAnswer(text, questionID: "providers", choices: ["imap"], other: nil, comment: "Gmail later", by: "sil")
        try write(file, text)

        let toHandle = try await board.waitForReviews(card: nil, timeout: 5, interval: 1)
        XCTAssertEqual(toHandle.count, 1)
        XCTAssertEqual((toHandle.first?["items"] as? [Any])?.count, 0)
        let answered = try XCTUnwrap(toHandle.first?["questions"] as? [[String: Any]])
        XCTAssertEqual(answered.map { $0["id"] as? String }, ["providers"], "only the answered question is listed")
        XCTAssertEqual(answered[0]["answer"] as? [String], ["imap"])
        XCTAssertEqual(answered[0]["answer_labels"] as? [String], ["iCloud and IMAP"])
        XCTAssertEqual(answered[0]["answered_by"] as? String, "sil")
        XCTAssertEqual(answered[0]["to_handle"] as? Bool, true)
        XCTAssertEqual(((answered[0]["comments"] as? [[String: Any]])?.first?["text"]) as? String, "Gmail later")

        do { _ = try await board.closeReview(request: "PETS-001-mail-decisions", force: false); XCTFail("not finished") } catch is AgentBoardError {}

        // Handling fixes the answer; the request stays while a question is unanswered.
        var result = try await board.handleReviewItem(request: "PETS-001-mail-decisions", item: "providers", shippedTo: nil, keep: false)
        XCTAssertEqual(result["pending"] as? Int, 1)
        XCTAssertNil(result["closed"])
        text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        XCTAssertNotNil(Review.parse(text, folder: "f").questions[0].handledAt)
        XCTAssertThrowsError(try Review.applyAnswer(text, questionID: "providers", choices: ["icloud"], other: nil, by: "sil"))

        // The last question is answered and handled: the request is cleared away.
        try write(file, try Review.applyAnswer(text, questionID: "platforms", choices: ["mac", "ios"], other: nil, by: "sil"))
        result = try await board.handleReviewItem(request: "PETS-001-mail-decisions", item: "platforms", shippedTo: nil, keep: false)
        XCTAssertEqual(result["closed"] as? Int, 1)
        XCTAssertFalse(exists(file))
    }

    func testQuestionsAreCheckedAndJoinAnExistingRequest() async throws {
        _ = try await board.createReview(request: nil, card: nil, title: "Dogs", question: nil, notes: nil, uploads: [upload("dog")], agent: "claude")
        // An id is unique across the request's items and questions.
        do {
            _ = try await board.createReview(request: "dogs", card: nil, title: nil, question: nil, notes: nil, uploads: [],
                                             questions: [providers(id: "dog")], agent: "claude")
            XCTFail("id taken by an item")
        } catch is AgentBoardError {}
        do {
            let empty = Review.NewQuestion(id: "q", question: "Anything?", options: [])
            _ = try await board.createReview(request: "dogs", card: nil, title: nil, question: nil, notes: nil, uploads: [], questions: [empty], agent: "claude")
            XCTFail("nothing to answer with")
        } catch is AgentBoardError {}
        do {
            _ = try await board.createReview(request: nil, card: nil, title: "Nothing", question: nil, notes: nil, uploads: [], agent: "claude")
            XCTFail("neither items nor questions")
        } catch is AgentBoardError {}

        _ = try await board.createReview(request: "dogs", card: nil, title: nil, question: nil, notes: nil, uploads: [],
                                         questions: [providers()], agent: "claude")
        let parsed = Review.parse(try String(contentsOf: root.appendingPathComponent("Pets/review/dogs/review.md"), encoding: .utf8), folder: "f")
        XCTAssertEqual(parsed.items.map(\.id), ["dog"])
        XCTAssertEqual(parsed.questions.map(\.id), ["providers"])
        XCTAssertEqual(parsed.summary.pending, 2)
    }
}
