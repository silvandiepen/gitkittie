import AppKit
import SwiftUI

@main
struct GitFolderApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appModel)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appModel)
                .background(SettingsWindowConfigurator())
                .onAppear {
                    appModel.loadIfNeeded()
                }
        }
        .windowResizability(.contentSize)
    }

    init() {
        let model = AppModel()
        _appModel = State(initialValue: model)
        Task { @MainActor in
            model.loadIfNeeded()
            DispatchQueue.main.async {
                model.requestLaunchAtLoginIfNeeded()
            }
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
    }
}
