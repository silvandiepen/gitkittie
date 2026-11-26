import GitBudCore
import SwiftUI

@main
struct GitBudApp: App {
    @State private var model = AppModel()

    /// The main window's scene id: one window per app, since the app holds one repository.
    static let mainWindowID = "main"

    var body: some Scene {
        // A single window rather than a group: it is always in the Window menu, and
        // `openWindow(id:)` brings it forward instead of making a second one.
        Window("GitKittie Bud", id: Self.mainWindowID) {
            ContentView()
                .modifier(CaptureHooks())
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .background(SolidWindow())
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        // Room for the sidebar, the graph and a readable diff side by side.
        .defaultSize(width: 1440, height: 900)
        .commands {
            GitBudCommands(model: model)
        }

        // A commit in a window of its own: double-click it in History.
        WindowGroup("Commit", id: CommitWindow.windowID, for: String.self) { $commitID in
            if let commitID {
                CommitWindow(commitID: commitID)
                    .environment(model)
                    .background(SolidWindow())
                    .tint(Theme.accent)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1100, height: 780)

        Settings {
            SettingsScene()
                .environment(model)
        }
    }
}

/// The menu bar's own commands. Items with a shortcut have no `.disabled` and capture no model
/// state: SwiftUI syncs a menu item only at launch and when its menu is opened, so a shortcut
/// that was disabled at launch stayed dead after a repository was opened (GITKITTIE-099). Each
/// one asks the model when it runs and, when it can't act, says why in the main window's alert.
private struct GitBudCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                model.openRepositoryPanel()
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                guard model.canRun(.refresh) else { return showMainWindow() }
                Task { await model.reload() }
            }
            .keyboardShortcut("r", modifiers: [.command])

            Divider()

            ForEach(GitBudWorkspaceMode.allCases) { mode in
                Button(mode.title) {
                    guard model.canRun(.showWorkspace(mode)) else { return showMainWindow() }
                    model.workspaceMode = mode
                    showMainWindow()
                }
                .keyboardShortcut(shortcut(for: mode), modifiers: [.command])
            }
        }
    }

    /// The views and the alert live in the main window, which may be closed or behind a commit
    /// window; `openWindow(id:)` brings the one main window forward.
    private func showMainWindow() {
        openWindow(id: GitBudApp.mainWindowID)
    }

    private func shortcut(for mode: GitBudWorkspaceMode) -> KeyEquivalent {
        switch mode {
        case .history: return "1"
        case .changes: return "2"
        case .branches: return "3"
        case .pullRequests: return "4"
        }
    }
}

/// Launch hooks for screenshots and for checking a change by eye, like Tasks' own. Each is a
/// no-op when its variable is unset, so a normal launch behaves exactly as before.
///
/// - `GITBUD_OPEN=<path>` opens that repository.
/// - `GITBUD_COMMIT=<revision>` then opens that commit in its own window.
private struct CaptureHooks: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["GITBUD_OPEN"], !path.isEmpty else { return }
            await model.openRepository(URL(fileURLWithPath: path))
            if let revision = environment["GITBUD_COMMIT"],
               let commit = model.commits.first(where: { $0.id.hasPrefix(revision) || $0.decorations.contains(revision) }) {
                model.selectCommit(commit)
                openWindow(id: CommitWindow.windowID, value: commit.id)
            }
        }
    }
}
