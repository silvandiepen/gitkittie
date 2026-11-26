import GitBudCore
import GitKittieKit
import SwiftUI

/// The window, built like Tasks': a sidebar of places on the left, the selected place on the
/// right, and the repository-wide verbs in the window's toolbar. Conflicts take over the
/// canvas, because nothing else is safe to do until they are resolved.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingCommandPalette = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var updates = AppUpdates()

    var body: some View {
        Group {
            if model.repositoryURL == nil {
                NoRepositoryView()
                    .background(GitBudTheme.background)
            } else {
                repositoryWorkspace
            }
        }
        .checksForAppUpdates(updates)
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
            "GitKittie Bud",
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

        return NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $model.workspaceMode, updates: updates)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            VStack(spacing: 0) {
                if let undo = model.rewriteUndo {
                    UndoBanner(undo: undo)
                }
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(GitBudTheme.background)
            // The window's title is the repository in the sidebar; each surface names itself.
            .navigationTitle("")
            .toolbar { RepositoryToolbar() }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if model.hasConflicts {
            ScrollView {
                ConflictPanel()
                    .padding(18)
            }
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
                .font(.callout.weight(.semibold))
            Text("Saved to \(undo.safetyBranch)")
                .font(.caption.monospaced())
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
        .background(Color.green.opacity(0.10))
    }
}
