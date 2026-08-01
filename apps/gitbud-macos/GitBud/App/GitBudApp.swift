import GitBudCore
import SwiftUI

@main
struct GitBudApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") {
                    model.openRepositoryPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await model.reload() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.repositoryURL == nil)

                Divider()

                ForEach(GitBudWorkspaceMode.allCases) { mode in
                    Button(mode.title) {
                        model.workspaceMode = mode
                    }
                    .keyboardShortcut(shortcut(for: mode), modifiers: [.command])
                    .disabled(model.repositoryURL == nil)
                }
            }
        }

        Settings {
            SettingsScene()
                .environment(model)
        }
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
