import AppKit
import MailExtraction
import MailCompose
import SwiftUI

@main
struct GitMailApp: App {
    // Attachment text for search comes from the sandboxed GitMailExtractor.xpc, never this process.
    @State private var model = AppModel(extractor: IsolatedTextExtractor(serviceName: "app.hakobs.gitmail.extractor"))

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
            CommandGroup(after: .newItem) {
                Button("Import Messages…") { Task { await Platform.importMessages(into: model) } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.phase != .ready || model.isImporting)
            }
            CommandMenu("Message") {
                let selected = model.browser.selectedMessage
                // Read, flag, archive, trash, move: the marked or selected conversations, with Undo (GKM-015).
                MessageActionCommands(model: model)
                Divider()
                // Spaces and export (GKM-022, GKM-023): the marked conversations, or the selected one.
                Menu("Add to Space") {
                    ForEach(model.spaces.spaces) { space in
                        Button(space.name) {
                            Task {
                                await model.spaces.add(threads: model.browser.threadIDs(actingOn: nil), to: space.id)
                                model.browser.clearMarks()
                                await model.browser.reload()
                            }
                        }
                    }
                }
                .disabled(model.spaces.spaces.isEmpty || model.browser.threadIDs(actingOn: nil).isEmpty)
                Button("Export Conversation…") {
                    let threads = model.browser.threadIDs(actingOn: nil)
                    Task { await Platform.export(.threads(threads), what: "Conversation", model: model) }
                }
                .disabled(model.browser.threadIDs(actingOn: nil).isEmpty)
                Button("Export Message…") {
                    if let selected { Task { await Platform.export(.messages([selected.id]), what: "Message", model: model) } }
                }
                .disabled(selected == nil)
                Divider()
                Button("Next Conversation") { Task { await model.browser.selectNext() } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Conversation") { Task { await model.browser.selectPrevious() } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            }
            ComposeCommands(model: model)
            CommandGroup(after: .toolbar) {
                Button("Rebuild Search Index") { Task { await model.rebuildIndex() } }
                    .disabled(model.phase != .ready || model.isRebuildingIndex)
            }
        }

        // One window per draft; restored with its draft after a relaunch (GKM-013).
        WindowGroup("New Message", id: ComposeScene.id, for: DraftID.self) { $draftID in
            ComposeWindow(draftID: draftID)
                .environment(model)
                .background(SolidWindow())
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 700, height: 640)
        .commandsRemoved()
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

    /// Asks for `.eml` files or folders and imports them (GKM-012).
    @MainActor
    static func importMessages(into model: AppModel) async {
        let panel = NSOpenPanel()
        panel.title = "Import Messages"
        panel.message = "Choose .eml files, or folders that contain them."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .data, .folder]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await model.importMessages(from: panel.urls)
    }
}
