import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// ⌘N files the task on the board that is on screen (GITKITTIE-097), over a real folder
/// laid out like the shared tasks repo: a root board whose lanes `GitKittie` and `Morrow`
/// inherit (`lanes: []`).
@MainActor
final class NewTaskBoardTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var repo: AddedRepo!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-new-task-board-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-new-task-board-tests-\(UUID().uuidString)"
        try write("README.md", """
        ---
        config: board
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: in-progress
            name: In Progress
            folder: "2. In Progress"
            status: in-progress
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        ---
        """)
        for (folder, prefix) in [("GitKittie", "GITKITTIE"), ("Morrow", "MORROW")] {
            try write("\(folder)/README.md", "---\nconfig: project\nproject: \(folder)\nlanes: []\n---\n")
            try write("\(folder)/1. To do/\(prefix)-001-first.md", CardText.make(
                id: "\(prefix)-001", title: "First", project: folder, status: "todo"))
            for lane in ["2. In Progress", "5. Done"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("\(folder)/\(lane)"), withIntermediateDirectories: true)
            }
        }
        repo = AddedRepo(namespace: "folder", name: "tasks", branch: "", isPrivate: true,
                         boards: [SelectedBoard(folder: "GitKittie", name: "GitKittie"), SelectedBoard(folder: "Morrow", name: "Morrow")],
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

    private func cards(in folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("\(folder)/1. To do").path).sorted()
    }

    private func model() -> AppModel {
        let app = AppModel.testing(suite: suite, keychainService: "gk-new-task-board-tests")
        app.addedRepos = [repo]
        return app
    }

    private func open(_ app: AppModel, _ folder: String) async {
        await app.openBoard(repo, folder: folder)
        app.stopWatching()
        XCTAssertNil(app.errorMessage)
    }

    /// What the sheet does with what ⌘N asked for.
    private func createFromShortcut(_ app: AppModel, title: String) async throws {
        app.requestNewTask()
        XCTAssertFalse(app.isChoosingBoardForNewTask, "the board is on screen: no need to ask")
        let lane = try XCTUnwrap(app.newTaskLane)
        let id = await app.createTask(title: title, lane: lane, priority: nil, type: nil, assignee: nil, body: "")
        XCTAssertNotNil(id)
        app.stopWatching()
    }

    // MARK: The board on screen

    func testAfterSwitchingBoardsTheTaskGoesToTheBoardOnScreen() async throws {
        let app = model()
        await open(app, "GitKittie")
        await open(app, "Morrow")
        try await createFromShortcut(app, title: "Can't go back")
        XCTAssertEqual(try cards(in: "Morrow"), ["MORROW-001-first.md", "MORROW-002-can-t-go-back.md"])
        XCTAssertEqual(try cards(in: "GitKittie"), ["GITKITTIE-001-first.md"])
    }

    /// A change saved on one board reloads that board when it is done. Morrow was opened while
    /// it was being sent: the reload must not put the other board back under Morrow's name.
    func testABoardSwitchedToWhileAWriteIsSentStaysTheBoardForNewTasks() async throws {
        let app = model()
        await open(app, "GitKittie")
        let source = try XCTUnwrap(app.source)
        let path = "GitKittie/1. To do/GITKITTIE-001-first.md"
        let renamed = CardText.update(try await source.readText(path), set: ["title": "First, renamed"])
        // What every change on the board goes through (`updateCard`, comments, checklists, …).
        await app.performWrite {
            try await source.write(path: path, text: renamed, message: "Update GITKITTIE-001")
            // Sil clicks Morrow in the sidebar while the change is on its way.
            await self.open(app, "Morrow")
        }
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.activeBoardFolder, "Morrow")
        XCTAssertEqual(app.selectedProject?.folder, "Morrow", "the reload of GitKittie must not take Morrow's place")
        XCTAssertEqual(app.allCards.map(\.fields.id), ["MORROW-001"])

        try await createFromShortcut(app, title: "Can't go back")
        XCTAssertEqual(try cards(in: "Morrow"), ["MORROW-001-first.md", "MORROW-002-can-t-go-back.md"])
        XCTAssertEqual(try cards(in: "GitKittie"), ["GITKITTIE-001-first.md"])
    }

    /// ⌘N right after clicking a board, while it is still being read: the task is for that
    /// board, so it starts there once its lanes are known, without asking which board.
    func testWhileTheBoardOnScreenIsLoadingTheTaskStartsThereOnceItIsRead() async throws {
        let app = model()
        await open(app, "GitKittie")
        let opening = Task { await app.openBoard(repo, folder: "Morrow") }
        while !(app.isLoadingBoard && app.activeBoardFolder == "Morrow") { await Task.yield() }
        XCTAssertNil(app.board, "Morrow has not been on screen before: nothing to show yet")
        app.requestNewTask()
        XCTAssertFalse(app.isChoosingBoardForNewTask)
        await opening.value
        app.stopWatching()
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertEqual(app.selectedProject?.folder, "Morrow")
    }
}
