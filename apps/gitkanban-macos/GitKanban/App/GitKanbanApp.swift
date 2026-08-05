import SwiftUI
import GitKanbanKit

@main
struct GitKanbanApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(CaptureHooks.colorScheme)
                .onAppear { CaptureHooks.applyWindowSize() }
                .task {
                    // Test hook: launch with GITKANBAN_DEMO=1 to open the offline demo.
                    if CaptureHooks.isDemo {
                        await model.loadDemo()
                    } else {
                        await model.restore()
                    }
                }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Board") {
                    Task {
                        if let repo = model.activeRepo, let folder = model.activeBoardFolder {
                            await model.openBoard(repo, folder: folder)
                        }
                    }
                }
                .keyboardShortcut("r")
                .disabled(model.activeRepo == nil)

                Button("Find…") { model.isShowingSearch = true }
                    .keyboardShortcut("f")
                    .disabled(model.board == nil)
            }
        }
    }
}

/// Launch hooks that let `@sil/app-release` drive the app for App Store screenshots
/// (see `release/macos.json`). A capture has to be reproducible: same data, same
/// appearance, same size. Every hook is a no-op when its variable is unset, so a normal
/// launch behaves exactly as before.
enum CaptureHooks {
    private static let environment = ProcessInfo.processInfo.environment

    /// `GITKANBAN_DEMO=1` — load the offline demo board instead of restoring a session.
    static var isDemo: Bool { environment["GITKANBAN_DEMO"] == "1" }

    /// `GITKANBAN_APPEARANCE=light|dark` — pin the appearance so both variants are
    /// reproducible rather than following the system setting.
    static var colorScheme: ColorScheme? {
        switch environment["GITKANBAN_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// `GITKANBAN_WINDOW_SIZE=<width>x<height>` — App Store screenshots must land on one
    /// of Apple's fixed dimensions, and the window is otherwise free-floating.
    ///
    /// This resizes the `NSWindow` rather than constraining the root view: a fixed
    /// `.frame` on the content leaves SwiftUI unable to size the window at all when there
    /// is no remembered frame, and the window then never appears.
    @MainActor
    static func applyWindowSize() {
        guard let raw = environment["GITKANBAN_WINDOW_SIZE"] else { return }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return }
        let size = CGSize(width: parts[0], height: parts[1])
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }
            window.setContentSize(size)
            window.center()
        }
    }
}

/// Small AppKit helpers so the ported views can copy/open/save on macOS.
enum Platform {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Present a save panel to write `data` to a user-chosen location.
    @MainActor static func save(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}
