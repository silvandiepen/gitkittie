import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Updated-since-seen marks, card sorting and the listing-based board summary, over a real
/// temp folder board.
@MainActor
final class SeenStateTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-seen-\(UUID().uuidString)", isDirectory: true)
        suite = "gk-seen-tests-\(UUID().uuidString)"
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: doing
            name: In Progress
            folder: "2. In Progress"
            status: in-progress
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        priorities:
          - id: P0
          - id: P1
          - id: P2
        ---
        """)
        try write("Tasks/Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        try card("PETS-1", lane: "1. To do", priority: "P2", updated: -7200)
        try card("PETS-2", lane: "1. To do", priority: "P0", updated: -1800)
        try card("PETS-3", lane: "1. To do", priority: "P1", updated: -86_400)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Pets/2. In Progress"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Pets/5. Done"), withIntermediateDirectories: true)
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

    private func card(_ id: String, lane: String, priority: String, updated secondsAgo: TimeInterval) throws {
        let text = CardText.make(id: id, title: id, project: "Pets", status: "todo",
                                 priority: priority, type: nil, assignee: nil, body: "")
        let stamp = Review.timestamp(Date(timeIntervalSinceNow: secondsAgo))
        try write("Tasks/Pets/\(lane)/\(id).md", CardText.update(text, set: ["updated_at": stamp]))
    }

    private var repo: AddedRepo {
        AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                  boards: [SelectedBoard(folder: "Tasks/Pets", name: "Pets")],
                  kind: .localFolder(path: root.path, bookmark: nil))
    }

    private func opened() async -> AppModel {
        let model = AppModel(appGroup: suite, keychainService: "gk-seen-tests", migratesLegacyStorage: false)
        await model.openBoard(repo, folder: "Tasks/Pets")
        model.stopWatching()
        return model
    }

    private func cards(_ model: AppModel) -> [Card] { model.board!.columns.first { $0.lane.id == "todo" }!.cards }

    func testNothingIsUnseenOnFirstOpenAndUpdatesAfterItAre() async throws {
        let model = await opened()
        XCTAssertEqual(model.unseenCount, 0, "what was there before the first open counts as seen")

        // An agent updates a card after that.
        try card("PETS-1", lane: "1. To do", priority: "P2", updated: 60)
        await model.openBoard(repo, folder: "Tasks/Pets")
        model.stopWatching()
        let updated = try XCTUnwrap(cards(model).first { $0.fields.id == "PETS-1" })
        XCTAssertTrue(model.isUnseen(updated))
        XCTAssertEqual(model.unseenCount, 1)

        // Marking everything seen moves the baseline to now, which is still before that update.
        model.seenBaselines["\(repo.id)|Tasks/Pets"] = Date(timeIntervalSinceNow: 120)
        XCTAssertFalse(model.isUnseen(updated))
    }

    func testOpeningACardMarksItSeenAndSurvivesARelaunch() async throws {
        let model = await opened()
        model.seenBaselines["\(repo.id)|Tasks/Pets"] = Date(timeIntervalSinceNow: -3600)
        let recent = try XCTUnwrap(cards(model).first { $0.fields.id == "PETS-2" })   // updated 30 min ago
        let old = try XCTUnwrap(cards(model).first { $0.fields.id == "PETS-1" })      // updated 2 h ago
        XCTAssertTrue(model.isUnseen(recent))
        XCTAssertFalse(model.isUnseen(old))

        model.markSeen(recent)
        XCTAssertFalse(model.isUnseen(recent))

        let relaunched = AppModel(appGroup: suite, keychainService: "gk-seen-tests", migratesLegacyStorage: false)
        await relaunched.restore()
        relaunched.stopWatching()
        XCTAssertNotNil(relaunched.seenCards["\(repo.id)|Tasks/Pets|PETS-2"])
    }

    func testSorting() async throws {
        let model = await opened()
        model.cardSort = .priority
        XCTAssertEqual(model.sorted(cards(model)).map(\.fields.id), ["PETS-2", "PETS-3", "PETS-1"])
        model.cardSort = .updated
        XCTAssertEqual(model.sorted(cards(model)).map(\.fields.id), ["PETS-2", "PETS-1", "PETS-3"])
        model.seenBaselines["\(repo.id)|Tasks/Pets"] = Date(timeIntervalSinceNow: -5400)   // 1.5 h ago
        model.cardSort = .unseenFirst
        XCTAssertEqual(model.sorted(cards(model)).first?.fields.id, "PETS-2", "only PETS-2 changed after the baseline")
        model.cardSort = .board
        XCTAssertEqual(model.sorted(cards(model)).map(\.fields.id), cards(model).map(\.fields.id))
    }

    func testBoardSummaryCountsNewAndMovedCardsSinceLastOpened() async throws {
        let model = await opened()
        let summary = try XCTUnwrap(model.boardSummary(repo, "Tasks/Pets"))
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.changed, 0)
        XCTAssertEqual(summary.active, [BoardSummary.LaneCount(name: "To do", count: 3)])
        model.closeRepo()

        // Meanwhile: one card moves lane, one is new.
        try FileManager.default.moveItem(at: root.appendingPathComponent("Tasks/Pets/1. To do/PETS-1.md"),
                                         to: root.appendingPathComponent("Tasks/Pets/2. In Progress/PETS-1.md"))
        try card("PETS-4", lane: "1. To do", priority: "P1", updated: 0)
        await model.loadBoardSummary(repo, "Tasks/Pets", force: true)
        let changed = try XCTUnwrap(model.boardSummary(repo, "Tasks/Pets"))
        XCTAssertEqual(changed.total, 4)
        XCTAssertEqual(changed.changed, 2)
        XCTAssertEqual(changed.active.map(\.name), ["To do", "In Progress"])

        // Opening the board is looking at it.
        await model.openBoard(repo, folder: "Tasks/Pets")
        model.stopWatching()
        XCTAssertEqual(model.boardSummary(repo, "Tasks/Pets")?.changed, 0)
    }
}

/// A board's icon and colour live in its README and are remembered for the sidebar.
@MainActor
final class BoardAppearanceTests: XCTestCase {
    func testMergingAMemberRewritesOnlyThePeopleFields() {
        let card = "---\nid: PETS-001\ntitle: sil was here\nassignee: \"sil\"\nreviewer: herma\ncreated_by: sil\npicked_up_by: sil\n---\n\nBody by sil\n"
        let merged = AppModel.replacingValue(in: card, from: "sil", into: "Sil van Diepen")
        XCTAssertEqual(merged, "---\nid: PETS-001\ntitle: sil was here\nassignee: \"Sil van Diepen\"\nreviewer: herma\ncreated_by: sil\npicked_up_by: \"Sil van Diepen\"\n---\n\nBody by sil\n")
        XCTAssertNil(AppModel.replacingValue(in: card, from: "nobody", into: "x"))
        XCTAssertNil(AppModel.replacingValue(in: "no frontmatter, assignee: sil", from: "sil", into: "x"))
        let typed = "---\nid: PETS-002\ntype: bug\nepic: bug\n---\n\nBody\n"
        XCTAssertEqual(AppModel.replacingValue(in: typed, fields: ["type"], from: "bug", into: "fix"), "---\nid: PETS-002\ntype: fix\nepic: bug\n---\n\nBody\n")
    }

    func testSymbolCatalogueFiltersByNameAndSearchWords() {
        let catalog = SymbolCatalog(names: ["folder", "folder.fill", "gamecontroller", "character.ar", "tray"],
                                    order: ["tray", "folder", "folder.fill", "gamecontroller"],
                                    search: ["gamecontroller": ["play", "joystick"]], first: ["folder.fill"])
        XCTAssertEqual(catalog.symbols.map(\.name), ["folder.fill", "tray", "folder", "gamecontroller"])
        XCTAssertEqual(catalog.matching("fold").map(\.name), ["folder.fill", "folder"])
        XCTAssertEqual(catalog.matching("folder fill").map(\.name), ["folder.fill"])
        XCTAssertEqual(catalog.matching("Joystick").map(\.name), ["gamecontroller"])
        XCTAssertTrue(catalog.matching("nothing").isEmpty)
    }

    func testSystemSymbolCatalogueHasTheWholeSet() {
        let all = SymbolCatalog.system.symbols
        XCTAssertGreaterThan(all.count, 3000)
        XCTAssertEqual(all.first?.name, BoardAppearance.defaultIcon)
        XCTAssertFalse(SymbolCatalog.system.matching("pawprint").isEmpty)
    }

    func testIconAndColourAreWrittenToTheReadmeAndReadBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-look-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let readme = root.appendingPathComponent("Tasks/Pets/README.md")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Pets/1. To do"), withIntermediateDirectories: true)
        try Data("---\nconfig: project\nproject: Pets\nreview_path: \"../review\"\nlanes:\n  - id: todo\n    name: To do\n    folder: \"1. To do\"\n    status: todo\n---\n\n# Pets\n\nAbout pets.\n".utf8).write(to: readme)

        let suite = "gk-look-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = AppModel(appGroup: suite, keychainService: "gk-look-tests", migratesLegacyStorage: false)
        let board = SelectedBoard(folder: "Tasks/Pets", name: "Pets")
        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true, boards: [board],
                             kind: .localFolder(path: root.path, bookmark: nil))
        model.addedRepos = [repo]

        await model.saveBoardSettings(board, in: repo, name: "Pets & Co", icon: "pawprint.fill", color: "orange")
        XCTAssertNil(model.errorMessage)
        let text = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertTrue(text.contains("icon: \"pawprint.fill\"") || text.contains("icon: pawprint.fill"), text)
        XCTAssertTrue(text.contains("color: orange"))
        XCTAssertTrue(text.contains("review_path: \"../review\""))
        XCTAssertTrue(text.contains("About pets."))
        let config = try BoardStore.parseProjectConfig(yaml: try XCTUnwrap(BoardMarkdown.splitFrontmatter(text).0))
        XCTAssertEqual(config.icon, "pawprint.fill")
        XCTAssertEqual(config.color, "orange")
        XCTAssertEqual(config.lanes?.map(\.id), ["todo"])
        XCTAssertEqual(config.project, "Pets & Co")
        XCTAssertEqual(model.addedRepos[0].boards[0].icon, "pawprint.fill")
        XCTAssertEqual(model.addedRepos[0].boards[0].name, "Pets & Co")

        // Another device: nothing remembered yet, the listing brings it in.
        model.addedRepos[0].boards[0].icon = nil
        model.addedRepos[0].boards[0].color = nil
        model.addedRepos[0].boards[0].name = "Pets"
        await model.loadBoardSummary(model.addedRepos[0], "Tasks/Pets", force: true)
        XCTAssertEqual(model.addedRepos[0].boards[0].icon, "pawprint.fill")
        XCTAssertEqual(model.addedRepos[0].boards[0].color, "orange")
        XCTAssertEqual(model.addedRepos[0].boards[0].name, "Pets & Co")

        await model.saveBoardSettings(model.addedRepos[0].boards[0], in: model.addedRepos[0], name: "Pets & Co", icon: nil, color: nil)
        let cleared = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertFalse(cleared.contains("icon:"))
        XCTAssertFalse(cleared.contains("color:"))
        XCTAssertTrue(cleared.contains("review_path"))
        XCTAssertTrue(cleared.contains("Pets & Co"))
    }
}
