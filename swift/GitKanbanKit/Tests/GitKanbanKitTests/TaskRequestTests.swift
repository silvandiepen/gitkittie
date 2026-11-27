import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// `gitkittie-tasks://new?title=…&body=…` — another app's Make Task (GitKittie Mail, GKM-033) —
/// from `openTaskRequest(_:)`, where the Mac app delegate and the iPhone's `onOpenURL` hand it
/// in, to the new-task sheet and the card Create writes, over a real folder board. The app is
/// launched the way it is at run time: `restore()` reopens the board that was open last.
@MainActor
final class TaskRequestTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var repo: AddedRepo!

    /// What Mail sends for a message: the subject, and who and when with a link back.
    private let mailRequest = NewTaskRequest(
        title: "Invoice 2026-114 & the + sign",
        body: "From Ada Lovelace, 26 Nov 2026.\n\n[Open in Mail](gitkittie-mail://message/0b6c55b1-0000-4000-8000-000000000001/m-abc)")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-task-request-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-task-request-tests-\(UUID().uuidString)"
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
          - id: backlog
            name: Backlog
            folder: "0. Backlog"
            status: backlog
            backlog: true
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        ---
        """)
        try write("Tasks/Morrow/README.md", "---\nconfig: project\nproject: Morrow\nlanes: []\n---\n")
        try write("Tasks/Morrow/1. To do/MORROW-001-fix-the-door.md", CardText.make(
            id: "MORROW-001", title: "Fix the door", project: "Morrow", status: "todo"))
        for folder in ["0. Backlog", "5. Done"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Morrow/\(folder)"), withIntermediateDirectories: true)
        }
        repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                         boards: [SelectedBoard(folder: "Tasks/Morrow", name: "Morrow")],
                         kind: .localFolder(path: root.path, bookmark: nil))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        AppModel.removeTestStorage(suite)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func launch() -> AppModel {
        AppModel.testing(suite: suite, keychainService: "gk-task-request-tests")
    }

    private func previousRunOpenedTheBoard() async {
        let earlier = launch()
        earlier.addedRepos = [repo]
        earlier.persistAddedRepos()
        await earlier.openBoard(repo, folder: "Tasks/Morrow")
        earlier.stopWatching()
    }

    private func previousRunAddedTheBoardOnly() {
        let earlier = launch()
        earlier.addedRepos = [repo]
        earlier.persistAddedRepos()
    }

    private func restored() async -> AppModel {
        let app = launch()
        await app.restore()
        app.stopWatching()
        return app
    }

    // MARK: The URL

    /// What goes in comes out: `&`, `+`, `#`, `=`, line breaks, non-Latin text and emoji.
    func testARequestSurvivesItsURL() throws {
        let request = NewTaskRequest(title: "Q&A + 50% off #1 = 👩‍💻 Ελληνικά",
                                     body: "Line one\nLine two & three + four\n\n[Open](gitkittie-mail://message/a/m-b?x=1)")
        let url = request.url
        XCTAssertEqual(url.scheme, "gitkittie-tasks")
        XCTAssertEqual(url.host, "new")
        XCTAssertEqual(NewTaskRequest(url: url), request)
        XCTAssertEqual(NewTaskRequest(url: mailRequest.url), mailRequest)
    }

    /// A title is one line, control characters go, and both are cut at their limits.
    func testARequestIsCleanedAndCut() throws {
        let request = NewTaskRequest(title: "  Two\nlines\u{0007}\r\n ", body: "\u{0000}Kept\r\nbreaks\u{001B}")
        XCTAssertEqual(request.title, "Two lines")
        XCTAssertEqual(request.body, "Kept\nbreaks")
        let long = NewTaskRequest(title: String(repeating: "t", count: 1_000), body: String(repeating: "b", count: 50_000))
        XCTAssertEqual(long.title.count, NewTaskRequest.maximumTitleLength)
        XCTAssertEqual(long.body.count, NewTaskRequest.maximumBodyLength)
    }

    /// Only `gitkittie-tasks://new` with something in it is a request.
    func testOtherURLsAreNotRequests() throws {
        XCTAssertNil(NewTaskRequest(url: URL(string: "https://new?title=Hi")!))
        XCTAssertNil(NewTaskRequest(url: URL(string: "gitkittie-tasks://delete?title=Hi")!))
        XCTAssertNil(NewTaskRequest(url: URL(string: "gitkittie-tasks://new")!))
        XCTAssertNil(NewTaskRequest(url: URL(string: "gitkittie-tasks://new?title=%20%20&body=")!))
        XCTAssertEqual(NewTaskRequest(url: URL(string: "GITKITTIE-TASKS://New?title=Hi")!)?.title, "Hi")
    }

    /// The sheet keeps what was typed: an empty title takes the request's, a description gets
    /// it below.
    func testFillingKeepsWhatWasTyped() {
        XCTAssertEqual(mailRequest.filling(title: "", body: "").title, mailRequest.title)
        XCTAssertEqual(mailRequest.filling(title: "", body: "").body, mailRequest.body)
        let typed = mailRequest.filling(title: "Pay it", body: "Before Friday.\n")
        XCTAssertEqual(typed.title, "Pay it")
        XCTAssertEqual(typed.body, "Before Friday.\n\n" + mailRequest.body)
    }

    // MARK: Opened in Tasks

    /// With a board open, the request starts a task in its first open lane with the title and
    /// description filled in, and saves nothing; Create writes the card with the link.
    func testARequestStartsATaskOnTheOpenBoardAndSavesNothingUntilCreate() async throws {
        await previousRunOpenedTheBoard()
        let app = await restored()
        XCTAssertNotNil(app.board)

        XCTAssertTrue(app.openTaskRequest(mailRequest.url))
        XCTAssertEqual(app.newTaskLane?.id, "todo", "the first open lane, not the backlog")
        XCTAssertFalse(app.isChoosingBoardForNewTask)
        let todo = root.appendingPathComponent("Tasks/Morrow/1. To do")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: todo.path).count, 1, "nothing written yet")

        let request = try XCTUnwrap(app.takeNewTaskRequest())
        XCTAssertNil(app.takeNewTaskRequest(), "handed over once")
        let lane = try XCTUnwrap(app.newTaskLane)
        let id = await app.createTask(title: request.title, lane: lane, priority: nil, type: nil, assignee: nil, body: request.body)
        app.stopWatching()
        XCTAssertEqual(id, "MORROW-002")
        let card = try String(contentsOf: todo.appendingPathComponent("MORROW-002-invoice-2026-114-the-sign.md"), encoding: .utf8)
        XCTAssertTrue(card.contains("[Open in Mail](gitkittie-mail://message/0b6c55b1-0000-4000-8000-000000000001/m-abc)"), card)
    }

    /// While the sheet is up the request joins it, in the lane it was opened in.
    func testARequestWhileTheSheetIsUpJoinsIt() async throws {
        await previousRunOpenedTheBoard()
        let app = await restored()
        let backlog = try XCTUnwrap(app.board?.columns.first { $0.lane.id == "backlog" }?.lane)
        app.newTaskLane = backlog
        app.openTaskRequest(mailRequest.url)
        XCTAssertEqual(app.newTaskLane?.id, "backlog")
        XCTAssertEqual(app.newTaskRequest, mailRequest)
    }

    /// No board open: the chooser asks; the picked board gets the request.
    func testWithNoBoardOpenTheChooserAsksAndThePickedBoardGetsTheRequest() async throws {
        previousRunAddedTheBoardOnly()
        let app = await restored()
        XCTAssertNil(app.board)
        app.openTaskRequest(mailRequest.url)
        XCTAssertTrue(app.isChoosingBoardForNewTask)
        XCTAssertNil(app.newTaskRequest, "not on a sheet until there is a board")

        await app.startNewTask(in: repo, board: repo.boards[0])
        app.stopWatching()
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertEqual(app.takeNewTaskRequest(), mailRequest)
    }

    /// A cancelled chooser does not leave the request for the next ⌘N.
    func testACancelledChooserDoesNotLeaveTheRequestForTheNextNewTask() async throws {
        previousRunAddedTheBoardOnly()
        let app = await restored()
        app.openTaskRequest(mailRequest.url)
        app.isChoosingBoardForNewTask = false   // Cancel
        app.requestNewTask()
        await app.startNewTask(in: repo, board: repo.boards[0])
        app.stopWatching()
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertNil(app.takeNewTaskRequest())
    }

    /// The link launched Tasks: the request waits for `restore()` and then starts the task on
    /// the board it reopens.
    func testARequestBeforeRestoreStartsTheTaskOnceTheLastBoardIsBack() async throws {
        await previousRunOpenedTheBoard()
        let app = launch()
        XCTAssertTrue(app.isRestoring)
        XCTAssertTrue(app.openTaskRequest(mailRequest.url))
        XCTAssertNil(app.newTaskLane)
        await app.restore()
        app.stopWatching()
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertEqual(app.takeNewTaskRequest(), mailRequest)
    }

    func testAURLThatIsNotARequestStartsNothing() async throws {
        await previousRunOpenedTheBoard()
        let app = await restored()
        XCTAssertFalse(app.openTaskRequest(URL(string: "gitkittie-tasks://new?title=")!))
        XCTAssertNil(app.newTaskLane)
        XCTAssertNotNil(app.errorMessage)
    }
}
