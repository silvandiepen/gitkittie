import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// A board's icon and colour are cached in the saved board list so the sidebar shows them
/// without opening the board. They used to be wiped whenever a README could not be read, and
/// whenever the board picker rewrote the list.
@MainActor
final class BoardAppearanceCacheTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-look-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-look-tests-\(UUID().uuidString)"
        try write("Tasks/README.md", "---\nconfig: board\nlanes:\n  - id: todo\n    name: To do\n    folder: \"1. To do\"\n    status: todo\n---\n")
        try write("Tasks/Pets/README.md", "---\nconfig: project\nproject: Pets\nicon: pawprint.fill\ncolor: orange\nlanes: []\n---\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Pets/1. To do"), withIntermediateDirectories: true)
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

    private func model(board: SelectedBoard) -> (AppModel, AddedRepo) {
        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                             boards: [board], kind: .localFolder(path: root.path, bookmark: nil))
        let model = AppModel.testing(suite: suite, keychainService: "gk-look-tests")
        model.addedRepos = [repo]
        return (model, repo)
    }

    private func saved(_ model: AppModel) -> SelectedBoard { model.addedRepos[0].boards[0] }

    func testAReadReadmeUpdatesTheCachedLook() async throws {
        let (model, repo) = model(board: SelectedBoard(folder: "Tasks/Pets", name: "Pets"))
        await model.loadBoardSummary(repo, "Tasks/Pets", force: true)
        XCTAssertEqual(saved(model).icon, "pawprint.fill")
        XCTAssertEqual(saved(model).color, "orange")
    }

    func testAnUnreadableReadmeKeepsTheCachedLook() async throws {
        var board = SelectedBoard(folder: "Tasks/Pets", name: "Pets")
        board.icon = "pawprint.fill"
        board.color = "orange"
        let (model, repo) = model(board: board)
        // The README cannot be read: the lane folders still list, the look is unknown.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Tasks/Pets/README.md"))
        await model.loadBoardSummary(repo, "Tasks/Pets", force: true)
        XCTAssertEqual(saved(model).icon, "pawprint.fill", "an unread README must not clear the icon")
        XCTAssertEqual(saved(model).color, "orange")
    }

    func testTheBoardPickerKeepsTheCachedLook() {
        var board = SelectedBoard(folder: "Tasks/Pets", name: "Pets")
        board.icon = "pawprint.fill"
        board.color = "orange"
        let (model, repo) = model(board: board)
        model.setBoards([SelectedBoard(folder: "Tasks/Pets", name: "Pets"), SelectedBoard(folder: "Tasks/Cats", name: "Cats")], for: repo.id)
        let pets = model.addedRepos[0].boards.first { $0.folder == "Tasks/Pets" }
        XCTAssertEqual(pets?.icon, "pawprint.fill")
        XCTAssertEqual(pets?.color, "orange")
        XCTAssertNil(model.addedRepos[0].boards.first { $0.folder == "Tasks/Cats" }?.icon)
    }
}
