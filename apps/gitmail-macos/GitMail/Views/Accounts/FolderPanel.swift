import AppKit
import Foundation

extension Platform {
    /// Asks for a folder with the system's open panel. The panel grants the sandboxed app access
    /// to what the person picks.
    @MainActor
    static func chooseFolder(title: String, prompt: String, message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
