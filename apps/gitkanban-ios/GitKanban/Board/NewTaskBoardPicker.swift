import GitKanbanKit
import GitKittieKit
import SwiftUI

/// "Which board is it for?": a new task asked for with no board open — another app's Make
/// Task (`gitkittie-tasks://new`, GKM-033). Picking a board opens it and starts the task in
/// its first open lane, with what was asked for filled in; nothing is saved until Create.
struct NewTaskBoardPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.addedRepos.filter { !$0.boards.isEmpty }) { repo in
                    Section(repo.displayName) {
                        ForEach(repo.boards) { board in
                            Button {
                                Task { await model.startNewTask(in: repo, board: board) }
                            } label: {
                                Label {
                                    Text(board.name).foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: board.icon ?? BoardAppearance.defaultIcon)
                                        .foregroundStyle(Color(boardColor: board.color))
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.addedRepos.allSatisfy({ $0.boards.isEmpty }) {
                    ContentUnavailableView("No Boards", systemImage: "square.stack.3d.up",
                                           description: Text("Add a board first."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.window)
            .navigationTitle("Which board?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
