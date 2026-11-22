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
                .background(SolidWindow())
                .tint(Theme.accent)
                .preferredColorScheme(CaptureHooks.colorScheme ?? .dark)
                .onAppear { CaptureHooks.applyWindowSize() }
                .task {
                    // Test hook: launch with GITKANBAN_DEMO=1 to open the offline demo.
                    if CaptureHooks.isDemo {
                        await model.loadDemo()
                        // `GITKANBAN_OPEN=settings|docs` — open that screen of the demo, for screenshots.
                        switch ProcessInfo.processInfo.environment["GITKANBAN_OPEN"] {
                        case "settings": model.wantsProjectSettings = true
                        case "docs":
                            if !model.hasDocs { _ = await model.createDoc(title: "Camera rules") }
                            model.isShowingDocs = true
                        default: break
                        }
                    } else {
                        await model.restore()
                        // `GITKANBAN_OPEN=docs` — start on the open board's Docs, for screenshots.
                        // `GITKANBAN_BOARD=<name>` — start on that board, for screenshots.
                        if let wanted = ProcessInfo.processInfo.environment["GITKANBAN_BOARD"] {
                            for repo in model.addedRepos {
                                if let board = repo.boards.first(where: { $0.name == wanted || $0.folder.hasSuffix(wanted) }) {
                                    await model.openBoard(repo, folder: board.folder)
                                    break
                                }
                            }
                        }
                        if ProcessInfo.processInfo.environment["GITKANBAN_OPEN"] == "docs" { model.isShowingDocs = true }
                        // `GITKANBAN_OPEN=all` — start on All Tasks; `GITKANBAN_CARD=<id>` — with that task selected;
                        // `GITKANBAN_VIEW=list|calendar` — in that view. For screenshots.
                        if ProcessInfo.processInfo.environment["GITKANBAN_OPEN"] == "all" { model.isShowingAllTasks = true }
                        if let id = ProcessInfo.processInfo.environment["GITKANBAN_CARD"] { model.selectedCard = model.card(withID: id) }
                        if let view = ProcessInfo.processInfo.environment["GITKANBAN_VIEW"].flatMap(BoardViewMode.init(rawValue:)) { model.boardViewMode = view }
                        // Agents on this Mac reach the boards through the app (Agent Access).
                        await model.startAgentServerIfEnabled()
                        await model.startNotifications()
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

        // A task in a window of its own: double-click on the board, or Open in Panel.
        WindowGroup("Task", id: TaskPanel.windowID, for: String.self) { $cardID in
            if let cardID {
                TaskPanel(cardID: cardID)
                    .environment(model)
                    .background(SolidWindow())
                    .tint(Theme.accent)
                    .preferredColorScheme(CaptureHooks.colorScheme ?? .dark)
            }
        }
        .defaultSize(width: 920, height: 760)
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

/// Gives the window the app's own opaque background, in place of the system's translucent
/// one that takes a tint from the desktop picture, and keeps the whole app (sheets and
/// menus too) in the dark appearance the design is drawn in.
struct SolidWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.backgroundColor = NSColor(Theme.window)
            window.isOpaque = true
            if CaptureHooks.colorScheme == nil { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
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
