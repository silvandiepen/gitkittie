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
}
