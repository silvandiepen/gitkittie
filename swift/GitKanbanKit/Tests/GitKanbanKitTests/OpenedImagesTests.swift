import CoreGraphics
import GitKittieKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GitKanbanKit

/// Images opened in Tasks — a screenshot dragged onto the Dock icon, Open With
/// (GITKITTIE-105) — from `openFiles(_:)`, where the app delegate's `application(_:open:)`
/// hands them in, through `startTask(fromImages:)` to the card and its attachments, over a
/// real folder board and real image files on disk. The app is launched the way it is at
/// run time: `restore()` reopens the board that was open last.
@MainActor
final class OpenedImagesTests: XCTestCase {
    private var root: URL!
    private var files: URL!
    private var suite: String!
    private var repo: AddedRepo!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-opened-images-\(UUID().uuidString)", isDirectory: true)
        files = FileManager.default.temporaryDirectory.appendingPathComponent("gk-opened-images-files-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-opened-images-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        // A backlog lane first: opened images land in To do, the first open lane.
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
        try? FileManager.default.removeItem(at: files)
        AppModel.removeTestStorage(suite)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// An image file on disk, as macOS saves a screenshot: `name` in the files folder.
    private func imageFile(_ name: String, as type: UTType, width: Int = 240, height: Int = 160) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(TaskImage.encode(try XCTUnwrap(context.makeImage()), as: type))
        let url = files.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A launch of the app: a fresh model over the stored state, not restored yet.
    private func launch() -> AppModel {
        AppModel.testing(suite: suite, keychainService: "gk-opened-images-tests")
    }

    /// The state a previous run left: the folder added, and `Tasks/Morrow` open last.
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

    // MARK: The board is open

    /// A screenshot dropped on the Dock icon while a board is open starts a new task in
    /// its first open lane holding the image; a TIFF becomes a JPEG; anything that is not
    /// an image is left out. Creating it writes the card and the attachments.
    func testOpenedImagesStartANewTaskOnTheOpenBoardAndBecomeItsAttachments() async throws {
        await previousRunOpenedTheBoard()
        let app = await restored()
        XCTAssertNotNil(app.board)
        XCTAssertNil(app.newTaskLane)

        let png = try imageFile("Screenshot 2026-11-26 at 10.15.00.png", as: .png)
        let tiff = try imageFile("scan.tiff", as: .tiff)
        let notes = files.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: notes)

        let opened = await app.openFiles([png, notes, tiff])
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(app.newTaskLane?.id, "todo", "the first open lane, not the backlog")
        XCTAssertFalse(app.isChoosingBoardForNewTask, "a board is open: no need to ask")
        let images = app.takeNewTaskImages()
        XCTAssertEqual(images.map(\.fileExtension), ["png", "jpg"])
        XCTAssertEqual(images.first?.data, try Data(contentsOf: png), "a PNG is kept byte for byte")

        // What the new-task sheet does with them when Create is pressed.
        let lane = try XCTUnwrap(app.newTaskLane)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let result = await app.createTask(fromImages: images, title: "Door handle is loose", lane: lane,
                                          at: formatter.date(from: "20261126-101500")!)
        let made = try XCTUnwrap(result)
        XCTAssertEqual(made.cardID, "MORROW-002")
        XCTAssertEqual(made.attached, ["screenshot-20261126-101500-1.png", "screenshot-20261126-101500-2.jpg"])
        XCTAssertEqual(made.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "Tasks/Morrow/1. To do/MORROW-002-door-handle-is-loose.md").path))
        let attachments = root.appendingPathComponent("Tasks/Morrow/attachments/MORROW-002")
        XCTAssertEqual(try Data(contentsOf: attachments.appendingPathComponent("screenshot-20261126-101500-1.png")),
                       try Data(contentsOf: png))
        let jpeg = try Data(contentsOf: attachments.appendingPathComponent("screenshot-20261126-101500-2.jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    /// Opened while the new-task sheet is already up: the images join that task, and the
    /// sheet stays in the lane it was opened in.
    func testImagesOpenedWhileTheNewTaskSheetIsUpJoinIt() async throws {
        await previousRunOpenedTheBoard()
        let app = await restored()
        let backlog = try XCTUnwrap(app.board?.columns.first { $0.lane.id == "backlog" }?.lane)
        app.newTaskLane = backlog
        await app.openFiles([try imageFile("one.png", as: .png)])
        XCTAssertEqual(app.newTaskLane?.id, "backlog")
        XCTAssertEqual(app.newTaskImages.count, 1)
    }

    // MARK: No board open

    /// With no board open the chooser asks which board; picking one opens it and starts
    /// the task there with the images.
    func testWithNoBoardOpenTheChooserAsksAndThePickedBoardGetsTheImages() async throws {
        previousRunAddedTheBoardOnly()
        let app = await restored()
        XCTAssertNil(app.board)

        await app.openFiles([try imageFile("one.png", as: .png), try imageFile("two.jpg", as: .jpeg)])
        XCTAssertTrue(app.isChoosingBoardForNewTask)
        XCTAssertNil(app.newTaskLane)
        XCTAssertTrue(app.newTaskImages.isEmpty, "not on a sheet until there is a board")

        await app.startNewTask(in: repo, board: repo.boards[0])
        app.stopWatching()
        XCTAssertFalse(app.isChoosingBoardForNewTask)
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertEqual(app.takeNewTaskImages().map(\.fileExtension), ["png", "jpg"])
    }

    /// The chooser was cancelled: ⌘N later starts a task without those images.
    func testACancelledChooserDoesNotLeaveTheImagesForTheNextNewTask() async throws {
        previousRunAddedTheBoardOnly()
        let app = await restored()
        await app.openFiles([try imageFile("one.png", as: .png)])
        XCTAssertTrue(app.isChoosingBoardForNewTask)
        app.isChoosingBoardForNewTask = false   // Cancel

        app.requestNewTask()
        XCTAssertTrue(app.isChoosingBoardForNewTask)
        await app.startNewTask(in: repo, board: repo.boards[0])
        app.stopWatching()
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertTrue(app.newTaskImages.isEmpty)
    }

    // MARK: Cold launch

    /// The drop launched Tasks: the images arrive before the model has restored, wait,
    /// and start the task on the board `restore()` reopens.
    func testImagesOpenedBeforeRestoreStartTheTaskOnceTheLastBoardIsBack() async throws {
        await previousRunOpenedTheBoard()
        let app = launch()
        XCTAssertTrue(app.isRestoring)

        let opened = await app.openFiles([try imageFile("Screenshot.png", as: .png)])
        XCTAssertEqual(opened, 1)
        XCTAssertNil(app.newTaskLane, "nothing to start a task on yet")
        XCTAssertFalse(app.isChoosingBoardForNewTask)

        await app.restore()
        app.stopWatching()
        XCTAssertFalse(app.isRestoring)
        XCTAssertNotNil(app.board)
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertEqual(app.takeNewTaskImages().map(\.fileExtension), ["png"])
    }

    /// Cold launch with no board open last: after restoring it asks which board.
    func testImagesOpenedBeforeRestoreWithNoBoardAskWhichBoard() async throws {
        previousRunAddedTheBoardOnly()
        let app = launch()
        await app.openFiles([try imageFile("Screenshot.png", as: .png)])
        await app.restore()
        XCTAssertNil(app.board)
        XCTAssertTrue(app.isChoosingBoardForNewTask)
        await app.startNewTask(in: repo, board: repo.boards[0])
        app.stopWatching()
        XCTAssertEqual(app.newTaskLane?.id, "todo")
        XCTAssertEqual(app.takeNewTaskImages().count, 1)
    }

    // MARK: Not images

    func testFilesThatAreNotImagesStartNothing() async throws {
        await previousRunOpenedTheBoard()
        let app = await restored()
        let notes = files.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: notes)
        // Named like an image, but not one.
        let fake = files.appendingPathComponent("fake.png")
        try Data("still not an image".utf8).write(to: fake)

        let opened = await app.openFiles([notes, fake])
        XCTAssertEqual(opened, 0)
        XCTAssertNil(app.newTaskLane)
        XCTAssertFalse(app.isChoosingBoardForNewTask)
        XCTAssertNotNil(app.errorMessage)
    }
}
