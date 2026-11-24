import GitKittieKit
import XCTest
@testable import GitKanbanKit

@MainActor
final class NewTaskShortcutTests: XCTestCase {
    private func column(_ id: String, backlog: Bool? = nil, terminal: Bool? = nil) -> Column {
        Column(lane: Lane(id: id, name: id, folder: id, status: id, terminal: terminal, backlog: backlog), cards: [])
    }

    func testNewTasksStartInTheFirstLaneThatIsNotBacklogOrDone() {
        let columns = [column("backlog", backlog: true), column("todo"), column("done", terminal: true)]
        XCTAssertEqual(AppModel.newTaskLane(in: columns)?.id, "todo")
        XCTAssertEqual(AppModel.newTaskLane(in: [column("done", terminal: true)])?.id, "done")
        XCTAssertNil(AppModel.newTaskLane(in: []))
    }

    func testWithNoBoardOpenItAsksForTheBoard() {
        let model = AppModel()
        model.requestNewTask()
        XCTAssertTrue(model.isChoosingBoardForNewTask)
        XCTAssertNil(model.newTaskLane)
    }

    func testOnTheDemoBoardItOpensTheTaskThere() async {
        let model = AppModel()
        await model.loadDemo()
        model.isShowingAllTasks = true
        model.requestNewTask()
        XCTAssertEqual(model.newTaskLane?.name, "To do")
        XCTAssertFalse(model.isShowingAllTasks)
        XCTAssertFalse(model.isChoosingBoardForNewTask)
    }
}
