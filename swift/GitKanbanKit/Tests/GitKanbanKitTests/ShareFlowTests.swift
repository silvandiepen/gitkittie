import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// What the iOS share extension does through `AppModel`, end-to-end over a real temp
/// folder: read the added boards from storage shared with the app, open one transiently,
/// create a card and attach a screenshot to it by id.
@MainActor
final class ShareFlowTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-share-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-share-tests-\(UUID().uuidString)"
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
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
        try write("Tasks/Morrow/1. To do/login-button-is-cut-off.md", CardText.make(
            id: "login-button-is-cut-off", title: "Login button is cut off", project: "Morrow",
            status: "todo", priority: nil, type: nil, assignee: nil, order: "1", body: ""))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func model() -> AppModel {
        AppModel(appGroup: suite, keychainService: "gk-share-tests", migratesLegacyStorage: false)
    }

    /// The app adds a folder board; a second model over the same storage (the extension) sees it.
    private func addBoardInApp() async throws -> AddedRepo {
        let app = model()
        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                             boards: [SelectedBoard(folder: "Tasks/Morrow", name: "Morrow")],
                             kind: .localFolder(path: root.path, bookmark: nil))
        app.addedRepos = [repo]
        app.persistAddedRepos()
        await app.openBoard(repo, folder: "Tasks/Morrow")
        app.stopWatching()
        return repo
    }

    func testExtensionSeesBoardsAddedInTheApp() async throws {
        let repo = try await addBoardInApp()
        let share = model()
        await share.restoreForSharing()
        XCTAssertEqual(share.addedRepos.map(\.id), [repo.id])
        XCTAssertEqual(share.lastOpenedBoard?.folder, "Tasks/Morrow")
        XCTAssertNil(share.board, "restoring for sharing must not open a board on its own")
    }

    func testTransientOpenCreatesCardAndAttachesScreenshotWithoutChangingTheLastBoard() async throws {
        let repo = try await addBoardInApp()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removeObject(forKey: "gitkanban.activeBoard")

        let share = model()
        await share.restoreForSharing()
        await share.openBoard(repo, folder: "Tasks/Morrow", transient: true)
        XCTAssertNil(share.errorMessage)
        XCTAssertNil(defaults.string(forKey: "gitkanban.activeBoard"), "a transient open is not remembered")

        let lane = try XCTUnwrap(share.quickCreateDefaultLane)
        XCTAssertEqual(lane.id, "todo")
        // Same title as an existing card: the new one must get its own file.
        let id = await share.createTask(title: "Login button is cut off", lane: lane,
                                        priority: nil, type: nil, assignee: nil, body: "Seen on the sign-in screen.")
        XCTAssertEqual(id, "login-button-is-cut-off-2")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let attached = await share.attachFile(toCardID: try XCTUnwrap(id), data: png, filename: "screenshot-20261120-101500.png")
        XCTAssertTrue(attached)

        let card = root.appendingPathComponent("Tasks/Morrow/1. To do/login-button-is-cut-off-2.md")
        XCTAssertTrue(try String(contentsOf: card, encoding: .utf8).contains("Seen on the sign-in screen."))
        let image = root.appendingPathComponent("Tasks/Morrow/attachments/login-button-is-cut-off-2/screenshot-20261120-101500.png")
        XCTAssertEqual(try Data(contentsOf: image), png)
    }

    /// A board of numbered cards: a card made in the app takes the next number, counted
    /// over every lane and over cards added since the board was opened.
    func testNewCardOnANumberedBoardGetsTheNextNumber() async throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("Tasks/Morrow/1. To do/login-button-is-cut-off.md"))
        try write("Tasks/Morrow/1. To do/MORROW-007-fix-the-door.md", CardText.make(
            id: "MORROW-007", title: "Fix the door", project: "Morrow", status: "todo"))
        try write("Tasks/Morrow/5. Done/MORROW-041-paint-the-wall.md", CardText.make(
            id: "MORROW-041", title: "Paint the wall", project: "Morrow", status: "done"))
        let repo = try await addBoardInApp()
        let share = model()
        await share.restoreForSharing()
        await share.openBoard(repo, folder: "Tasks/Morrow", transient: true)
        // Someone else adds a card after the board was opened here.
        try write("Tasks/Morrow/1. To do/MORROW-042-added-meanwhile.md", CardText.make(
            id: "MORROW-042", title: "Added meanwhile", project: "Morrow", status: "todo"))

        let lane = try XCTUnwrap(share.quickCreateDefaultLane)
        let first = await share.createTask(title: "The way people hold wood is weird", lane: lane,
                                           priority: nil, type: nil, assignee: nil, body: "")
        XCTAssertEqual(first, "MORROW-043")
        let second = await share.createTask(title: "Watchtower!", lane: lane, priority: nil, type: nil, assignee: nil, body: "")
        XCTAssertEqual(second, "MORROW-044")

        let card = root.appendingPathComponent("Tasks/Morrow/1. To do/MORROW-043-the-way-people-hold-wood-is-weird.md")
        XCTAssertTrue(try String(contentsOf: card, encoding: .utf8).contains("id: MORROW-043"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tasks/Morrow/1. To do/MORROW-044-watchtower.md").path))
        let attached = await share.attachFile(toCardID: "MORROW-043", data: Data([1]), filename: "shot.png")
        XCTAssertTrue(attached)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tasks/Morrow/attachments/MORROW-043/shot.png").path))
    }

    func testCreateTaskReturnsNilWhenNothingIsOpen() async {
        let share = model()
        await share.restoreForSharing()
        let lane = Lane(id: "todo", name: "To do", folder: "1. To do", status: "todo")
        let id = await share.createTask(title: "Orphan", lane: lane, priority: nil, type: nil, assignee: nil, body: "")
        XCTAssertNil(id)
    }
}
