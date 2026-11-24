import AppKit
import MailStore
import SwiftUI
import UniformTypeIdentifiers

/// A space's colour name (the Tasks board palette, `SpaceAppearance.colors`) as a colour.
enum SpaceLook {
    static func color(_ name: String) -> Color {
        switch name {
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "brown": .brown
        case "gray": .gray
        default: .blue
        }
    }

    /// What a dragged conversation carries: its thread ids, one per line, behind a prefix so a
    /// plain text drop from elsewhere is never read as conversations.
    static let dragPrefix = "gitkittie-mail-threads:"

    static func dragPayload(_ threadIDs: [String]) -> String { dragPrefix + threadIDs.joined(separator: "\n") }

    static func threadIDs(fromDrop items: [String]) -> [String] {
        items.filter { $0.hasPrefix(dragPrefix) }
            .flatMap { $0.dropFirst(dragPrefix.count).split(separator: "\n").map(String.init) }
    }
}

/// Small AppKit edges for spaces and the library.
extension Platform {
    /// Asks where to save an attachment. The name is display text made safe, never a path.
    @MainActor
    static func chooseSaveLocation(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }

    /// Asks for a folder and exports into it (GKM-023).
    @MainActor
    static func export(_ selection: ExportSelection, what: String, model: AppModel) async {
        guard let folder = await chooseFolder(
            title: "Export \(what)", prompt: "Export Here",
            message: "A new folder is made here with the original .eml files, their Markdown copies and attachments. Nothing that only this Mac knows (read state, sync position, search index) goes with them.")
        else { return }
        await model.export(selection, to: folder)
    }
}
