import AppKit
import SwiftUI
import GitKanbanKit

/// The app's AppKit side: it owns the model so files opened in Tasks reach it however they
/// come — a screenshot dragged onto the Dock icon, Open With in Finder — including the drop
/// that launches the app, which arrives before any window or SwiftUI view exists
/// (GITKITTIE-105) — and `gitkittie-tasks://new` links from other apps (GKM-033). The image
/// types Tasks opens are declared in `project.yml` (`CFBundleDocumentTypes`, rank Alternate:
/// never the default image app), the URL scheme there too (`CFBundleURLTypes`).
///
/// SwiftUI's `onOpenURL` is not used: a `WindowGroup` app does not reliably get the files
/// of a Dock drop there, and may open a new window for each.
@MainActor
final class TasksAppDelegate: NSObject, NSApplicationDelegate {
    /// The main window's scene id.
    static let mainWindowID = "main"

    let model = AppModel()
    /// Opens a main window; set by the first one that appears, for when all are closed.
    var openMainWindow: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        // `gitkittie-tasks://new?…` from another app (GitKittie Mail's Make Task, GKM-033)
        // arrives here too, beside the files.
        let requests = urls.filter { !$0.isFileURL }
        let files = urls.filter(\.isFileURL)
        Task {
            // Before the model has restored (a cold launch) it keeps them until then.
            if !files.isEmpty { await model.openFiles(files) }
            if let request = requests.last { model.openTaskRequest(request) }
            showMainWindow()
        }
    }

    /// The new-task sheet (or the board chooser) shows in the main window: bring it forward,
    /// or open one when every window was closed.
    private func showMainWindow() {
        NSApp.activate()
        let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true }
        if let main {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// Hands the delegate a way to open the main window, which only a view can reach.
struct RegistersMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: TasksAppDelegate

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.openMainWindow = { [openWindow] in openWindow(id: TasksAppDelegate.mainWindowID) }
        }
    }
}
