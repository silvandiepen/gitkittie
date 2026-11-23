import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Moving a card to another project of the same folder, over a real temp folder.
@MainActor
final class MoveProjectTests: XCTestCase {
    private var root: URL!
    private let pets = SelectedBoard(folder: "Tasks/Pets", name: "Pets")
    private let farm = SelectedBoard(folder: "Tasks/Farm", name: "Farm")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-move-\(UUID().uuidString)", isDirectory: true)
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: review
            name: In Review
            folder: "3. In Review"
            status: in-review
        ---
        """)
        try write("Tasks/Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        // Farm has its own lanes: no "In Review".
        try write("Tasks/Farm/README.md", """
        ---
        config: project
        project: Farm
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: done
            name: Done
            folder: "5. Done"
            status: done
        ---
        """)
        try card("Tasks/Pets/1. To do/PETS-007-feed-the-cat.md", id: "PETS-007", title: "Feed the cat", status: "todo")
        try card("Tasks/Pets/3. In Review/loose-note.md", id: "loose-note", title: "Loose note", status: "in-review")
        try card("Tasks/Farm/1. To do/FARM-041-mend-fence.md", id: "FARM-041", title: "Mend fence", status: "todo")
        try card("Tasks/Farm/5. Done/FARM-009-buy-hay.md", id: "FARM-009", title: "Buy hay", status: "done")
        try write("Tasks/Pets/attachments/PETS-007/cat.png", "png-bytes")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func card(_ path: String, id: String, title: String, status: String) throws {
        try write(path, CardText.make(id: id, title: title, project: "Pets", status: status,
                                      priority: nil, type: nil, assignee: nil, body: "Body of \(id)"))
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    private func opened() async -> AppModel {
        let model = AppModel()
        let repo = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                             boards: [pets, farm], kind: .localFolder(path: root.path, bookmark: nil))
        model.addedRepos = [repo]
        await model.openBoard(repo, folder: "Tasks/Pets")
        model.stopWatching()
        return model
    }

    private func find(_ model: AppModel, _ id: String) throws -> Card {
        try XCTUnwrap(model.allCards.first { $0.fields.id == id })
    }

    func testOtherProjectsAreTheRestOfTheRepo() async {
        let model = await opened()
        XCTAssertEqual(model.otherProjects.map(\.name), ["Farm"])
    }

    func testAPrefixedCardAsksAndRenumberingMovesItWithItsAttachments() async throws {
        let model = await opened()
        await model.startMove(try find(model, "PETS-007"), to: farm)
        let plan = try XCTUnwrap(model.pendingProjectMove, "a card with another project's prefix raises the id question")
        XCTAssertEqual(plan.suggestedID, "FARM-042")
        XCTAssertEqual(plan.lane.name, "To do")
        XCTAssertTrue(exists("Tasks/Pets/1. To do/PETS-007-feed-the-cat.md"), "nothing moves before the answer")

        await model.finishMove(plan, renumber: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.pendingProjectMove)
        XCTAssertFalse(exists("Tasks/Pets/1. To do/PETS-007-feed-the-cat.md"))
        let moved = try read("Tasks/Farm/1. To do/FARM-042-feed-the-cat.md")
        XCTAssertTrue(moved.contains("id: FARM-042"))
        XCTAssertTrue(moved.contains("project: Farm"))
        XCTAssertTrue(moved.contains("Body of PETS-007"))
        XCTAssertEqual(try read("Tasks/Farm/attachments/FARM-042/cat.png"), "png-bytes")
        XCTAssertFalse(exists("Tasks/Pets/attachments/PETS-007/cat.png"))
        XCTAssertFalse(model.allCards.contains { $0.fields.id == "PETS-007" }, "it is gone from the open board")
    }

    func testKeepingTheIDLeavesFileNameAndAttachmentsFolderAlone() async throws {
        let model = await opened()
        await model.startMove(try find(model, "PETS-007"), to: farm)
        let plan = try XCTUnwrap(model.pendingProjectMove)
        await model.finishMove(plan, renumber: false)
        let moved = try read("Tasks/Farm/1. To do/PETS-007-feed-the-cat.md")
        XCTAssertTrue(moved.contains("id: PETS-007"))
        XCTAssertTrue(moved.contains("project: Farm"))
        XCTAssertEqual(try read("Tasks/Farm/attachments/PETS-007/cat.png"), "png-bytes")
    }

    func testASlugCardIsOfferedANumberAndKeepsItsSlugInTheFileName() async throws {
        let model = await opened()
        // "In Review" does not exist in Farm: it lands in Farm's first lane.
        await model.startMove(try find(model, "loose-note"), to: farm)
        let plan = try XCTUnwrap(model.pendingProjectMove, "Farm numbers its cards, so a slug id raises the question too")
        XCTAssertEqual(plan.suggestedID, "FARM-042")
        XCTAssertEqual(plan.lane.name, "To do")
        await model.finishMove(plan, renumber: true)
        XCTAssertNil(model.errorMessage)
        let moved = try read("Tasks/Farm/1. To do/FARM-042-loose-note.md")
        XCTAssertTrue(moved.contains("id: FARM-042"))
        XCTAssertTrue(moved.contains("status: todo"))
        XCTAssertTrue(moved.contains("project: Farm"))
        XCTAssertFalse(exists("Tasks/Pets/3. In Review/loose-note.md"))
    }

    func testMovingIntoAProjectThatDoesNotNumberAsksNothing() async throws {
        let model = await opened()
        model.closeRepo()
        let repo = model.addedRepos[0]
        await model.openBoard(repo, folder: "Tasks/Farm")
        model.stopWatching()
        // Pets only has PETS-007 numbered plus a slug card: its majority still numbers, so
        // remove the numbered one to make it a project of plain slugs.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Tasks/Pets/1. To do/PETS-007-feed-the-cat.md"))
        await model.startMove(try find(model, "FARM-041"), to: pets)
        XCTAssertNil(model.pendingProjectMove)
        XCTAssertTrue(exists("Tasks/Pets/1. To do/FARM-041-mend-fence.md"))
    }

    func testNextIDFollowsTheTargetsNumbering() {
        XCTAssertEqual(AppModel.nextID(for: "ARVIK-075", among: ["GITKIT-148-a.md", "GITKIT-009-b.md", "notes.md"]), "GITKIT-149")
        XCTAssertNil(AppModel.nextID(for: "GITKIT-012", among: ["GITKIT-148-a.md"]), "same prefix: nothing to ask")
        XCTAssertEqual(AppModel.nextID(for: "review-doesn-t-work", among: ["GITKIT-148-a.md"]), "GITKIT-149", "a slug id gets a number")
        XCTAssertEqual(AppModel.fileName("review-doesn-t-work.md", from: "review-doesn-t-work", to: "GITKIT-149"), "GITKIT-149-review-doesn-t-work.md")
        XCTAssertEqual(AppModel.fileName("ARVIK-075-hall-pilot.md", from: "ARVIK-075", to: "GITKIT-149"), "GITKIT-149-hall-pilot.md")
        XCTAssertNil(AppModel.nextID(for: "ARVIK-075", among: ["loose.md"]), "the target does not number its cards")
    }
}
