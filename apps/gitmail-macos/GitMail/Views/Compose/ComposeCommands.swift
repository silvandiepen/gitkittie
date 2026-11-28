import AppKit
import MailCompose
import SwiftUI

// The menu items with shortcuts stay enabled and check when they run: SwiftUI syncs a menu item
// only at launch and when its menu is opened, not when the model or the window in front changes
// (GITKITTIE-098, `MenuCommand`).

/// New Message (⌘N) in the File menu, with Attach Files… (⇧⌘A) for the compose window in front.
struct ComposeCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                guard model.canRun(.newMessage) else { return }
                open { await model.composeNew() }
            }
            .keyboardShortcut("n")
            Button("Attach Files…") {
                guard let draft = ComposeWindows.inFront else { return model.actionError = ComposeWindowDirectory.noWindowInFront }
                draft.requestAttach()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }

    private func open(_ make: @escaping @MainActor () async -> DraftID?) {
        Task { @MainActor in
            if let id = await make() { openWindow(id: ComposeScene.id, value: id) }
        }
    }
}

/// The top of the Message menu: Send and Delete Draft for the compose window in front;
/// Reply (⌘R), Reply All (⇧⌘R) and Forward (⇧⌘F) for the selected message.
struct ReplyCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Send") {
            guard let draft = ComposeWindows.inFront else { return model.actionError = ComposeWindowDirectory.noWindowInFront }
            // Already sending: the window shows it.
            guard draft.canSend else { return NSSound.beep() }
            draft.send()
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        Button("Delete Draft…") {
            guard let draft = ComposeWindows.inFront else { return model.actionError = ComposeWindowDirectory.noWindowInFront }
            draft.requestDiscard()
        }
        Divider()
        Button("Reply") { answer(.reply) }
            .keyboardShortcut("r")
        Button("Reply All") { answer(.replyAll) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Forward") { answer(.forward) }
            .keyboardShortcut("f", modifiers: [.command, .shift])
    }

    private func answer(_ action: AppModel.ComposeAction) {
        guard model.canRun(.answer(action)) else { return }
        Task { @MainActor in
            if let id = await model.compose(action) { openWindow(id: ComposeScene.id, value: id) }
        }
    }
}

/// The compose windows of this app, by their NSWindow: what Send, Attach Files… and Delete
/// Draft… act on.
@MainActor
enum ComposeWindows {
    static let directory = ComposeWindowDirectory()

    /// The compose window in front (the key window), when it is one.
    static var inFront: ComposeWindowCommands? { directory.commands(inFront: NSApp.keyWindow) }
}

/// Registers a compose window's commands for the window it is in, and removes them when the
/// view leaves that window.
struct ComposeWindowRegistration: NSViewRepresentable {
    let commands: ComposeWindowCommands

    final class Probe: NSView {
        var commands: ComposeWindowCommands?
        private weak var registered: NSWindow?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if registered !== newWindow { unregister() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            register()
        }

        func register() {
            guard let window, let commands else { return }
            ComposeWindows.directory.set(commands, for: window)
            registered = window
        }

        func unregister() {
            if let registered { ComposeWindows.directory.set(nil, for: registered) }
            registered = nil
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.commands = commands
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.commands = commands
        nsView.register()
    }

    static func dismantleNSView(_ nsView: Probe, coordinator: ()) {
        nsView.commands = nil
        nsView.unregister()
    }
}

/// The same actions in the main window's toolbar.
struct ComposeToolbar: ToolbarContent {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { open { await model.compose(.reply) } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply (⌘R)")
                .disabled(!model.canAnswer)
            Button { open { await model.compose(.replyAll) } } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .help("Reply All (⇧⌘R)")
                .disabled(!model.canAnswer)
            Button { open { await model.compose(.forward) } } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward (⇧⌘F)")
                .disabled(!model.canAnswer)
            Button { open { await model.composeNew() } } label: { Label("New Message", systemImage: "square.and.pencil") }
                .help(model.writeRefusal ?? "New Message (⌘N)")
                .disabled(model.sending == nil || !model.canWrite)
        }
    }

    private func open(_ make: @escaping @MainActor () async -> DraftID?) {
        Task { @MainActor in
            if let id = await make() { openWindow(id: ComposeScene.id, value: id) }
        }
    }
}
