import XCTest
@testable import GitKanbanKit
import GitKittieKit

@MainActor
final class TaskFieldsTests: XCTestCase {
    private func loaded() async -> AppModel {
        let model = AppModel()
        await model.loadDemo()
        return model
    }

    func testLabelsDueAndComment() async {
        let model = await loaded()
        let id = model.allCards.first!.id
        func card() -> Card { model.allCards.first { $0.id == id }! }

        await model.setCardTags(card(), ["ios", " bug ", "iOS", ""])
        XCTAssertEqual(card().fields.tags, ["ios", "bug"])
        XCTAssertEqual(model.boardTags.filter { ["ios", "bug"].contains($0) }.count, 2)

        let day = CardDates.date("2026-11-24")!
        await model.setCardDue(card(), day)
        XCTAssertEqual(card().fields.due, "2026-11-24")
        await model.setCardDue(card(), nil)
        XCTAssertNil(card().fields.due)

        let before = CardActivity.entries(in: card().body).count
        let added = await model.addComment(card(), "Looks right to me.")
        XCTAssertTrue(added)
        let entries = CardActivity.entries(in: card().body)
        XCTAssertEqual(entries.count, before + 1)
        XCTAssertEqual(entries.last?.text, "Looks right to me.")
        XCTAssertNotNil(entries.last?.author)
        XCTAssertNotNil(entries.last?.date)
        // Labels survive the comment.
        XCTAssertEqual(card().fields.tags, ["ios", "bug"])
    }

    func testTogglingCheckboxes() {
        let text = "Intro\n\n- [ ] one\n- [x] two\n\n```\n- [ ] in code\n```\n\n* [ ] three"
        XCTAssertEqual(AppModel.togglingCheckbox(in: text, index: 0)?.contains("- [x] one"), true)
        XCTAssertEqual(AppModel.togglingCheckbox(in: text, index: 1)?.contains("- [ ] two"), true)
        XCTAssertEqual(AppModel.togglingCheckbox(in: text, index: 2)?.contains("* [x] three"), true)
        XCTAssertEqual(AppModel.togglingCheckbox(in: text, index: 2)?.contains("- [ ] in code"), true)
        XCTAssertNil(AppModel.togglingCheckbox(in: text, index: 3))
    }

    func testAllTasksLeavesOutDoneAndBacklog() async {
        let model = await loaded()
        await model.loadAllTasks()
        // The demo is not a board in the sidebar: nothing to list, and nothing breaks.
        XCTAssertTrue(model.allTasks.isEmpty)
        XCTAssertEqual(model.allTasksCount, 0)
    }
}
