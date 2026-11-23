import GitBudCore
import GitKittieKit
import SwiftUI

/// Repository-wide verbs in the window's toolbar — the ones that act on the repo rather
/// than on a selected item. Fetch, pull and push earn permanent space because they are
/// what you reach for most.
struct RepositoryToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if model.isLoading || model.isSyncingRemote || model.isRewriting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button {
                    model.fetchRemote()
                } label: {
                    Label("Fetch", systemImage: "arrow.clockwise")
                }
                .help("Fetch from the remote")
                .disabled(busy)

                Button {
                    model.pullCurrentBranchWithRebase()
                } label: {
                    Label("Pull", systemImage: "arrow.down")
                }
                .help(model.worktreeFiles.isEmpty ? "Pull with rebase" : "Commit or stash your changes before pulling")
                .disabled(busy || !model.worktreeFiles.isEmpty)

                Button {
                    model.pushCurrentBranch()
                } label: {
                    Label("Push", systemImage: "arrow.up")
                }
                .help("Push the current branch")
                .disabled(busy)
            }

            Button {
                Task { await model.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Reload from disk (⌘R)")
            .disabled(model.isLoading)
        }
    }

    private var busy: Bool {
        model.isSyncingRemote || model.isRewriting || model.hasConflicts
    }
}
