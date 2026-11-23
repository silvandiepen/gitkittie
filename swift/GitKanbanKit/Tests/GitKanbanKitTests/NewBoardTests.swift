import GitKittieKit
import XCTest
@testable import GitKanbanKit

@MainActor
final class NewBoardTests: XCTestCase {
    func testFirstLookSuggestsNothing() {
        XCTAssertEqual(AppModel.newFolders(now: ["Arvik", "Dry"], known: nil, selected: ["Arvik"]), [])
    }

    func testAFolderThatAppearedIsNew() {
        XCTAssertEqual(AppModel.newFolders(now: ["Arvik", "Dry", "Morrow"], known: ["Arvik", "Dry"], selected: ["Arvik"]), ["Morrow"])
    }

    func testABoardAlreadyInTheSidebarIsNotNew() {
        XCTAssertEqual(AppModel.newFolders(now: ["Arvik", "Morrow"], known: ["Arvik"], selected: ["Arvik", "Morrow"]), [])
    }

    func testParentsOfTheSelectedBoards() {
        let boards = [SelectedBoard(folder: "Arvik", name: "Arvik"), SelectedBoard(folder: "work/boards/Dry", name: "Dry"),
                      SelectedBoard(folder: "", name: "Root")]
        XCTAssertEqual(AppModel.boardParents(of: boards), ["", "work/boards"])
    }

    // Over a real folder: a board made elsewhere is found, a plain folder is not.
    func testANewBoardFolderIsSuggestedOnceAndCanBeAdded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-newboard-\(UUID().uuidString)", isDirectory: true)
        let suite = "gk-newboard-tests-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("Tasks/README.md", "---\nconfig: board\nlanes:\n  - id: todo\n    name: To do\n    folder: \"1. To do\"\n    status: todo\n---\n")
        try write("Tasks/Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        try write("Tasks/Pets/1. To do/.keep", "")

        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                             boards: [SelectedBoard(folder: "Tasks/Pets", name: "Pets")],
                             kind: .localFolder(path: root.path, bookmark: nil))
        let model = AppModel(appGroup: suite, keychainService: "gk-newboard-tests", migratesLegacyStorage: false)
        model.addedRepos = [repo]

        await model.refreshBoardSuggestions()
        XCTAssertTrue(model.boardSuggestions.isEmpty, "the first look only notes what is there")

        try write("Tasks/Dogs/README.md", "---\nconfig: project\nproject: Dogs\nlanes: []\n---\n")
        try write("Tasks/Dogs/1. To do/.keep", "")
        try write("Tasks/notes/readme.txt", "not a board")
        await model.refreshBoardSuggestions()
        XCTAssertEqual(model.boardSuggestions.map(\.folder), ["Tasks/Dogs"])
        XCTAssertEqual(model.boardSuggestions.first?.name, "Dogs")

        let suggestion = try XCTUnwrap(model.boardSuggestions.first)
        model.addSuggestedBoard(suggestion)
        XCTAssertEqual(model.addedRepos.first?.boards.map(\.folder).sorted(), ["Tasks/Dogs", "Tasks/Pets"])
        await model.refreshBoardSuggestions()
        XCTAssertTrue(model.boardSuggestions.isEmpty)
    }

    func testNotNowIsNotAskedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-newboard-\(UUID().uuidString)", isDirectory: true)
        let suite = "gk-newboard-tests-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        func make(_ board: String) throws {
            let lane = root.appendingPathComponent("\(board)/1. To do")
            try FileManager.default.createDirectory(at: lane, withIntermediateDirectories: true)
            try Data("---\nconfig: project\nproject: \(board)\nlanes:\n  - id: todo\n    name: To do\n    folder: \"1. To do\"\n    status: todo\n---\n".utf8)
                .write(to: root.appendingPathComponent("\(board)/README.md"))
        }
        try make("Pets")
        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                             boards: [SelectedBoard(folder: "Pets", name: "Pets")],
                             kind: .localFolder(path: root.path, bookmark: nil))
        let model = AppModel(appGroup: suite, keychainService: "gk-newboard-tests", migratesLegacyStorage: false)
        model.addedRepos = [repo]
        await model.refreshBoardSuggestions()
        try make("Dogs")
        await model.refreshBoardSuggestions()
        let suggestion = try XCTUnwrap(model.boardSuggestions.first)
        model.dismissBoardSuggestion(suggestion)
        await model.refreshBoardSuggestions()
        XCTAssertTrue(model.boardSuggestions.isEmpty)
        XCTAssertEqual(model.addedRepos.first?.boards.map(\.folder), ["Pets"])
    }
}
