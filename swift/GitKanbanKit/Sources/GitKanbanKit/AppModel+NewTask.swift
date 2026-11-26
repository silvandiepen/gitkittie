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
    /// A board that is open but still being read gets the task as soon as its lanes are known.
    public func requestNewTask() {
        newTaskAwaitsBoard = nil
        if let lane = newTaskLaneOnScreen {
            showOpenBoardsTasks()
            newTaskLane = lane
        } else if isLoadingBoard, let key = openBoardKey, activeRepo != nil {
            showOpenBoardsTasks()
            newTaskAwaitsBoard = key
        } else {
            isChoosingBoardForNewTask = true
        }
    }

    /// The lane a new task starts in on the board that is open: `nil` while that board is not
    /// read yet (`board` is then empty, or still the project of the board before it).
    var newTaskLaneOnScreen: Lane? {
        guard let board, let project = selectedProject else { return nil }
        if let folder = activeBoardFolder, activeRepo != nil, project.folder != folder { return nil }
        return Self.newTaskLane(in: board.columns)
    }

    /// The board ⌘N waited for is read: start the task on it, or ask if it could not be read.
    func startAwaitedNewTask(onBoard key: String) {
        guard let awaited = newTaskAwaitsBoard else { return }
        // Another board was opened since: what ⌘N was pressed for is no longer on screen.
        guard awaited == key, openBoardKey == key else { newTaskAwaitsBoard = nil; return }
        newTaskAwaitsBoard = nil
        if let lane = newTaskLaneOnScreen { newTaskLane = lane } else { isChoosingBoardForNewTask = true }
    }

    private func showOpenBoardsTasks() {
        isShowingReviews = false
        isShowingDocs = false
        isShowingAllTasks = false
    }

    /// The board picked for a new task: open it, then start the task in its first lane.
    public func startNewTask(in repo: AddedRepo, board chosen: SelectedBoard) async {
        isChoosingBoardForNewTask = false
        isShowingReviews = false
        isShowingDocs = false
        isShowingAllTasks = false
        newTaskAwaitsBoard = nil
        await openBoard(repo, folder: chosen.folder)
        // Only on the board that was picked, and only once it is on screen.
        guard activeRepo?.id == repo.id, activeBoardFolder == chosen.folder else { return }
        newTaskLane = newTaskLaneOnScreen
    }
}
