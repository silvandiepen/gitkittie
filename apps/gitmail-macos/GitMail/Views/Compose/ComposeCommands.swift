import MailCompose
import SwiftUI

/// New Message (⌘N) in the File menu, with Attach Files… (⇧⌘A) for the compose window in front.
struct ComposeCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// The draft of the compose window in front, if one is.
    @FocusedValue(\.composeDraft) private var draft

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { open { await model.composeNew() } }
                .keyboardShortcut("n")
                .disabled(model.sending == nil)
            Button("Attach Files…") { draft?.requestAttach() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(draft == nil)
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
    @FocusedValue(\.composeDraft) private var draft
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Send") { draft?.send() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(draft?.canSend != true)
        Button("Delete Draft…") { draft?.requestDiscard() }
            .disabled(draft == nil)
        Divider()
        Button("Reply") { open { await model.compose(.reply) } }
            .keyboardShortcut("r")
            .disabled(!model.canAnswer)
        Button("Reply All") { open { await model.compose(.replyAll) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.canAnswer)
        Button("Forward") { open { await model.compose(.forward) } }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!model.canAnswer)
    }

    private func open(_ make: @escaping @MainActor () async -> DraftID?) {
        Task { @MainActor in
            if let id = await make() { openWindow(id: ComposeScene.id, value: id) }
        }
    }
}

/// What the menu bar can do in the compose window in front: the window publishes this as its
/// focused scene value.
struct ComposeWindowCommands {
    var canSend: Bool
    var send: @MainActor () -> Void
    var requestAttach: @MainActor () -> Void
    var requestDiscard: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var composeDraft: ComposeWindowCommands?
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
                .help("New Message (⌘N)")
                .disabled(model.sending == nil)
        }
    }

    private func open(_ make: @escaping @MainActor () async -> DraftID?) {
        Task { @MainActor in
            if let id = await make() { openWindow(id: ComposeScene.id, value: id) }
        }
    }
}
