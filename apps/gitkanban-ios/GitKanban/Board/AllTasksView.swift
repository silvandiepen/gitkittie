import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The open tasks of every board on the home screen: per board, what is neither done nor
/// in the backlog. Tapping a task opens its board with that task on screen.
struct AllTasksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var startSearching = false
    @State private var query = ""
    @State private var isSearching = false

    private var boards: [BoardTasks] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return model.allTasks }
        return model.allTasks.map { board in
            var board = board
            board.open = board.open.filter { task in
                [task.card.fields.title, task.card.fields.id, task.card.fields.assignee ?? "", task.lane.name]
                    .contains { $0.lowercased().contains(text) }
            }
            return board
        }
    }

    var body: some View {
        Group {
            if model.allTasks.isEmpty && model.isLoadingAllTasks {
                ProgressView("Reading every board…")
            } else {
                List {
                    ForEach(boards) { board in
                        if !board.open.isEmpty || board.problem != nil || query.isEmpty {
                            Section {
                                if let problem = board.problem {
                                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                                } else if board.open.isEmpty {
                                    Text("Nothing open.").font(.callout).foregroundStyle(.secondary)
                                }
                                ForEach(board.open) { task in
                                    Button {
                                        dismiss()
                                        Task { await model.openTask(task, on: board) }
                                    } label: { row(task, board) }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Image(systemName: board.board.icon ?? BoardAppearance.defaultIcon)
                                        .foregroundStyle(Color(boardColor: board.board.color))
                                    Text(board.board.name).textCase(nil).font(.headline).foregroundStyle(.primary)
                                    Text("\(board.open.count)").foregroundStyle(.secondary)
                                }
                            }
                            .themedRows()
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .themedList()
            }
        }
        .navigationTitle("All Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search open tasks")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .refreshable { await model.loadAllTasks() }
        .task {
            if startSearching { isSearching = true }
            await model.loadAllTasks()
        }
    }

    private func row(_ task: BoardTasks.OpenTask, _ board: BoardTasks) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.card.fields.title.isEmpty ? task.card.fields.id : task.card.fields.title)
                .font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(laneColor(task.lane, board.config)).frame(width: 8, height: 8)
                    Text(task.lane.name).font(.caption).foregroundStyle(.secondary)
                }
                TaskMetaLine(card: task.card, priorities: board.config.priorities)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
