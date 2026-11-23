import Foundation
import GitKittieKit

extension AppModel {
    /// The lane a new task starts in: the first one that is neither the backlog nor a finished
    /// lane, so ⌘N never files a task as already done. Falls back to the first lane.
    public nonisolated static func newTaskLane(in columns: [Column]) -> Lane? {
        columns.first { $0.lane.backlog != true && $0.lane.terminal != true }?.lane ?? columns.first?.lane
    }

    /// ⌘N: a new task on the board that is open, or — with none open — the question which
    /// board it is for. Showing All Tasks, Reviews or Docs, the open board comes back first.
    public func requestNewTask() {
        if let columns = board?.columns, let lane = Self.newTaskLane(in: columns) {
            isShowingReviews = false
            isShowingDocs = false
            isShowingAllTasks = false
            newTaskLane = lane
        } else {
            isChoosingBoardForNewTask = true
        }
    }

    /// The board picked for a new task: open it, then start the task in its first lane.
    public func startNewTask(in repo: AddedRepo, board chosen: SelectedBoard) async {
        isChoosingBoardForNewTask = false
        isShowingReviews = false
        isShowingDocs = false
        isShowingAllTasks = false
        await openBoard(repo, folder: chosen.folder)
        if let columns = board?.columns { newTaskLane = Self.newTaskLane(in: columns) }
    }
}
