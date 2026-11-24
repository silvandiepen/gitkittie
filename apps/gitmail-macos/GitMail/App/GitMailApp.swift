import AppKit
import SwiftUI

@main
struct GitMailApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .background(SolidWindow())
                .tint(Theme.accent)
                // The GitKittie apps are navy: dark, like Tasks.
                .preferredColorScheme(.dark)
                .task { await model.open() }
        }
        .commands {
            // One window is the mail; there is nothing new to make yet.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Rebuild Search Index") { Task { await model.rebuildIndex() } }
                    .disabled(model.phase != .ready || model.isRebuildingIndex)
            }
        }
    }
}

/// Makes the window opaque in the app's own background colour, so the navy is the same on
/// every desktop picture (as in Tasks).
struct SolidWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.backgroundColor = NSColor(Theme.window)
            window.isOpaque = true
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Small AppKit edges the views use.
enum Platform {
    /// Shows a folder or file in the Finder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
