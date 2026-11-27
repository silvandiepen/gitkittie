import AppKit
import MailCore
import MailExtraction
import MailCompose
import SwiftUI

@main
struct GitMailApp: App {
    @State private var model: AppModel
    /// Which tab Settings opens on (GKM-066).
    @State private var settings = SettingsNavigation()
    /// Receives `gitkittie-mail://message/…` links (GKM-033).
    @NSApplicationDelegateAdaptor(MailAppDelegate.self) private var appDelegate

    init() {
        // Thin overlay scrollbars that only show while scrolling, whatever System Settings says
        // (the wide "Always" ones draw a light track across the dark window). This app's own
        // preference: it changes nothing for other apps.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        // Attachment text for search comes from the sandboxed GitMailExtractor.xpc, never this process.
        let model = AppModel(extractor: IsolatedTextExtractor(serviceName: "app.hakobs.gitmail.extractor"),
                             notifications: UserNotificationPoster())
        // Before launch finishes, so the notification that launched the app opens its message.
        model.respondToNotifications()
        _model = State(initialValue: model)
    }
    /// What the menu bar asks the mail window for (GKM-061).
    @State private var requests = MailWindowRequests()

    var body: some Scene {
        WindowGroup(id: MailAppDelegate.mainWindowID) {
            RootView()
                .environment(model)
                .environment(settings)
                .environment(requests)
                .frame(minWidth: 960, minHeight: 600)
                .background(SolidWindow())
                .tint(Theme.accent)
                // The GitKittie apps are navy: dark, like Tasks.
                .preferredColorScheme(.dark)
                .modifier(ReceivesMessageLinks(delegate: appDelegate, model: model))
                .task { await model.open() }
        }
        .commands {
            // File ▸ New Message and Attach Files… (ComposeCommands), then Import.
            CommandGroup(after: .newItem) {
                // No .disabled on an item with a shortcut: SwiftUI would keep the state from launch
                // until the menu is opened; the action checks the model instead (GITKITTIE-098).
                Button("Import Messages…") {
                    guard model.canRun(.importMessages) else { return }
                    Task { await Platform.importMessages(into: model) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                // Encrypted archive (GKM-032): everything in one encrypted file, and back.
                Button("Export Encrypted Archive…") { Task { await Platform.writeEncryptedArchive(model: model) } }
                    .disabled(model.phase != .ready || model.encryptedArchive.isWorking)
                Button("Restore Encrypted Archive…") { requests.restoresArchive = true }
                    .disabled(model.encryptedArchive.isWorking)
            }
            // One Message menu: Send and Reply first, then the actions on the conversations.
            // Items without a shortcut can only be chosen from the open menu, which SwiftUI syncs
            // as it opens, so their .disabled is current (GITKITTIE-098).
            CommandMenu("Message") {
                let selected = model.browser.selectedMessage
                ReplyCommands(model: model)
                Divider()
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
                // GitKittie Tasks and stable links (GKM-033).
                Button("Make Task…") {
                    if let selected { Task { await Platform.makeTask(from: selected.id, model: model) } }
                }
                .disabled(selected == nil)
                Button("Copy Link to Message") {
                    if let selected { Task { await Platform.copyLink(to: selected.id, model: model) } }
                }
                .disabled(selected == nil)
                Divider()
                // Pin for offline (GKM-036): download whole and keep, even attachments left at the provider.
                Button("Keep Message Offline") {
                    if let selected { Task { await model.pin(.message(selected.id)) } }
                }
                .disabled(selected == nil)
                Button("Keep Conversation Offline") {
                    Task { for thread in model.browser.threadIDs(actingOn: nil) { await model.pin(.thread(thread)) } }
                }
                .disabled(model.browser.threadIDs(actingOn: nil).isEmpty)
                Button("Don’t Keep Offline") {
                    Task {
                        if let selected { await model.unpin(.message(selected.id)) }
                        for thread in model.browser.threadIDs(actingOn: nil) { await model.unpin(.thread(thread)) }
                    }
                }
                .disabled(selected == nil && model.browser.threadIDs(actingOn: nil).isEmpty)
                Divider()
                Button("Next Conversation") { Task { await model.browser.selectNext() } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Conversation") { Task { await model.browser.selectPrevious() } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            }
            ComposeCommands(model: model)
            MailboxCommands(model: model, requests: requests, settings: settings)
            CommandGroup(after: .toolbar) {
                Button("Rebuild Search Index") { Task { await model.rebuildIndex() } }
                    .disabled(model.phase != .ready || model.isRebuildingIndex)
                OfflineStorageCommand(navigation: settings)
                    .disabled(model.phase != .ready)
            }
        }

        // Mail ▸ Settings… (⌘,): accounts and their mailboxes, notifications, storage (GKM-066).
        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
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

/// The app's AppKit side for links: a `gitkittie-mail://message/…` link opened anywhere (a
/// Tasks card, a note) reaches `application(_:open:)`, also when it launched the app, before
/// any window exists (GKM-033). SwiftUI's `onOpenURL` is not used: a `WindowGroup` app may open
/// a new window for each link. Links that come before the model is attached wait for it.
@MainActor
final class MailAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    private var model: AppModel?
    private var waiting: [URL] = []
    /// Opens a main window; set by the first one that appears, for when all are closed.
    var openMainWindow: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { waiting += urls; return }
        open(urls, in: model)
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let urls = waiting
        waiting = []
        if !urls.isEmpty { open(urls, in: model) }
    }

    private func open(_ urls: [URL], in model: AppModel) {
        guard let url = urls.last(where: { !$0.isFileURL }) else { return }
        Task {
            // Before the store is open the model keeps the link until it is.
            await model.openLink(url)
            showMainWindow()
        }
    }

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

/// Hands the delegate the model and a way to open the main window, which only a view can reach.
struct ReceivesMessageLinks: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let delegate: MailAppDelegate
    let model: AppModel

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.openMainWindow = { [openWindow] in openWindow(id: MailAppDelegate.mainWindowID) }
            delegate.attach(model)
        }
    }
}

/// Small AppKit edges the views use.
enum Platform {
    /// Shows a folder or file in the Finder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Make Task (GKM-033): asks GitKittie Tasks for a new task about the message. Tasks shows
    /// it in its new-task sheet; nothing is saved there until Create.
    @MainActor
    static func makeTask(from id: MailMessageID, model: AppModel) async {
        guard let handoff = await model.taskHandoff(for: id) else { return }
        if !NSWorkspace.shared.open(handoff.url) { model.actionError = TaskHandoff.notInstalled }
    }

    /// Copy Link to Message (GKM-033): the stable `gitkittie-mail://message/…` link.
    @MainActor
    static func copyLink(to id: MailMessageID, model: AppModel) async {
        guard let link = await model.link(to: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
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
