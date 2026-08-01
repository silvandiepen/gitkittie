import GitBudCore
import GitKit
import SwiftUI

/// The window. A sidebar of four surfaces, a toolbar of repository-wide verbs, and
/// whichever surface is selected. Conflicts take over the canvas, because nothing else
/// is safe to do until they are resolved.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingCommandPalette = false

    var body: some View {
        ZStack {
            GitBudTheme.background.ignoresSafeArea()

            if model.repositoryURL == nil {
                NoRepositoryView()
            } else {
                repositoryWorkspace
            }
        }
        .foregroundStyle(GitBudTheme.primaryText)
        .background {
            // Invisible shortcut host: ⌘K works wherever focus happens to be.
            Button("") { isShowingCommandPalette = true }
                .keyboardShortcut("k", modifiers: [.command])
                .opacity(0)
                .disabled(model.repositoryURL == nil)
        }
        .sheet(isPresented: $isShowingCommandPalette) {
            CommandPalette()
        }
        .alert(
            "GitBud",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var repositoryWorkspace: some View {
        @Bindable var model = model

        return HStack(spacing: 0) {
            Sidebar(selection: $model.workspaceMode)
                .frame(width: 200)
            Divider().overlay(.white.opacity(0.08))
            VStack(spacing: 0) {
                RepositoryToolbar()
                Divider().overlay(.white.opacity(0.08))
                if let undo = model.rewriteUndo {
                    UndoBanner(undo: undo)
                    Divider().overlay(.white.opacity(0.08))
                }
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if model.hasConflicts {
            ConflictPanel()
                .padding(18)
        } else {
            switch model.workspaceMode {
            case .history:
                HistoryView()
            case .changes:
                ChangesView()
            case .branches:
                BranchesView()
            case .pullRequests:
                PullRequestsView()
            }
        }
    }
}

/// Shown after a rewrite. One line, one way back — so history surgery never feels final.
private struct UndoBanner: View {
    @Environment(AppModel.self) private var model
    let undo: GitBudRewriteUndo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text(undo.summary)
                .font(.caption.weight(.semibold))
            Text("Saved to \(undo.safetyBranch)")
                .font(.caption2.monospaced())
                .foregroundStyle(GitBudTheme.secondaryText)
            Spacer()
            Button("Undo") {
                model.undoLastRewrite()
            }
            .disabled(model.isUndoingRewrite || !model.worktreeFiles.isEmpty)
            .help(model.worktreeFiles.isEmpty ? "Reset back to the safety branch" : "Commit or stash your changes first")
            Button {
                model.dismissRewriteUndo()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(GitBudTheme.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.green.opacity(0.08))
    }
}
