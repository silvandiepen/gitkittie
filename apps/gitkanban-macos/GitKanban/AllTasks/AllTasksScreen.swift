import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The open tasks of every board in the sidebar: per board, what is neither done nor in
/// the backlog. Clicking a task opens its board with that task selected.
struct AllTasksScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// Boards folded shut here, by id.
    @State private var folded: Set<String> = []

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

    private var total: Int { boards.reduce(0) { $0 + $1.open.count } }

    var body: some View {
        Group {
            if model.allTasks.isEmpty && model.isLoadingAllTasks {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the tasks of every board…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.allTasks.isEmpty {
                ContentUnavailableView("No Boards", systemImage: "tray",
                                       description: Text("Add a board to the sidebar to see its tasks here."))
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.loadAllTasks() } } label: {
                    if model.isLoadingAllTasks { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Read every board again")
                .disabled(model.isLoadingAllTasks)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search open tasks")
        .task { await model.loadAllTasks() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full").font(.title3).foregroundStyle(.tint)
                    Text("All Tasks").font(.title2.weight(.semibold))
                    Text("\(total) open").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(boards) { board in
                    if !board.open.isEmpty || board.problem != nil || query.isEmpty { section(board) }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ board: BoardTasks) -> some View {
        let isFolded = folded.contains(board.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    if isFolded { folded.remove(board.id) } else { folded.insert(board.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: board.board.icon ?? BoardAppearance.defaultIcon)
                        .foregroundStyle(Color(boardColor: board.board.color)).frame(width: 20)
                    Text(board.board.name).font(.headline)
                    Text("\(board.open.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isFolded ? -90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(board.board.name), \(board.open.count) open tasks, \(isFolded ? "folded" : "open")")

            if let problem = board.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if !isFolded {
                if board.open.isEmpty {
                    Text("Nothing open.").font(.callout).foregroundStyle(.tertiary).padding(.leading, 30)
                }
                VStack(spacing: 0) {
                    ForEach(board.open) { task in
                        Button { Task { await model.openTask(task, on: board) } } label: { row(task, board) }
                            .buttonStyle(.plain)
                        if task.id != board.open.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            }
        }
    }

    private func row(_ task: BoardTasks.OpenTask, _ board: BoardTasks) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(laneColor(task.lane, board.config)).frame(width: 8, height: 8)
                Text(task.lane.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            Text(task.card.fields.title.isEmpty ? task.card.fields.id : task.card.fields.title)
                .font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            TaskMetaLine(card: task.card, priorities: board.config.priorities)
                .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
