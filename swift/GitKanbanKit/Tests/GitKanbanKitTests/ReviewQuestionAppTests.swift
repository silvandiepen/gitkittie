import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Answering questions in a review request through the app model, over a real temp folder.
@MainActor
final class ReviewQuestionAppTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-questions-\(UUID().uuidString)", isDirectory: true)
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
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Mail/1. To do"), withIntermediateDirectories: true)
        try write("Tasks/Mail/review/MAIL-1-decisions/review.md", """
        ---
        config: review
        id: MAIL-1-decisions
        title: Decisions
        agent_only: keep
        items:
          - id: logo
            file: logo.png
            status: pending
            comments: []
        questions:
          - id: providers
            question: Which providers?
            select: one
            other: true
            options:
              - id: icloud
                label: iCloud only
              - id: imap
                label: iCloud and IMAP
            answer: []
            comments: []
          - id: platforms
            question: Where?
            select: many
            options:
              - id: mac
                label: Mac
              - id: ios
                label: iPhone
            answer: []
        ---
        """)
        try write("Tasks/Mail/review/MAIL-1-decisions/logo.png", "png-bytes")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func onDisk() throws -> ReviewRequest {
        Review.parse(try String(contentsOf: root.appendingPathComponent("Tasks/Mail/review/MAIL-1-decisions/review.md"), encoding: .utf8), folder: "f")
    }

    private func open() async -> AppModel {
        let model = AppModel()
        await model.openBoard(AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                                        boards: [SelectedBoard(folder: "Tasks/Mail", name: "Mail")],
                                        kind: .localFolder(path: root.path, bookmark: nil)), folder: "Tasks/Mail")
        return model
    }

    func testQuestionsWaitUntilAnsweredAndOneChoiceIsEnforced() async throws {
        let model = await open()
        var request = try XCTUnwrap(model.reviews.first)
        XCTAssertEqual(request.summary.pending, 3, "the item and both questions wait")
        XCTAssertEqual(model.pendingReviewCount, 3)

        // Two choices for a one-choice question are refused and nothing is written.
        let refused = await model.answer(request, question: request.questions[0], choices: ["icloud", "imap"], other: nil)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, ReviewError.oneChoiceOnly.errorDescription)
        XCTAssertFalse(try onDisk().questions[0].isAnswered)

        let written = await model.answer(request, question: request.questions[0], choices: ["imap"], other: nil, comment: "Gmail later")
        XCTAssertTrue(written)
        XCTAssertNil(model.errorMessage)
        request = model.reviews[0]
        XCTAssertEqual(request.questions[0].answer, ["imap"])
        XCTAssertEqual(request.questions[0].answeredBy, "sil")
        XCTAssertEqual(request.questions[0].comments.map(\.text), ["Gmail later"])
        XCTAssertEqual(request.summary.pending, 2)

        // Changed before the agent acted on it.
        await model.answer(request, question: request.questions[0], choices: [], other: "Fastmail")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try onDisk().questions[0].answerOther, "Fastmail")
        XCTAssertEqual(try onDisk().questions[0].answer, [])

        await model.answer(model.reviews[0], question: model.reviews[0].questions[1], choices: ["ios", "mac"], other: nil)
        XCTAssertEqual(try onDisk().questions[1].answer, ["mac", "ios"])
        XCTAssertEqual(model.reviews[0].summary.questionsDescription, "2 questions, all answered")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("Tasks/Mail/review/MAIL-1-decisions/review.md"), encoding: .utf8)
            .contains("agent_only: keep"))
        model.closeRepo()
    }

    func testApprovingAllNeverAnswersQuestions() async throws {
        let model = await open()
        await model.decideAll(model.reviews[0], status: .approved)
        await model.commentAll(model.reviews[0], text: "Looked at it")
        XCTAssertNil(model.errorMessage)
        let request = try onDisk()
        XCTAssertEqual(request.items[0].status, .approved)
        XCTAssertTrue(request.questions.allSatisfy { !$0.isAnswered && $0.comments.isEmpty })
        XCTAssertEqual(request.summary.pending, 2)
        XCTAssertEqual(request.summary.pendingItems, 0)
        XCTAssertEqual(AppModel.waitingLine(request.summary), "2 questions to answer")
        model.closeRepo()
    }
}
