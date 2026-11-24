import SwiftUI

/// Read/unread, flag and conversation navigation, for the Message menu (GKM-012).
struct MessageStateCommands: View {
    let model: AppModel

    var body: some View {
        let selected = model.browser.selectedMessage
        Button(selected?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
            if let selected { Task { await model.browser.setUnread(!selected.isUnread, for: selected.id) } }
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(selected == nil)
        Button(selected?.isFlagged == true ? "Unflag" : "Flag") {
            if let selected { Task { await model.browser.setFlagged(!selected.isFlagged, for: selected.id) } }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(selected == nil)
        Divider()
        Button("Next Conversation") { Task { await model.browser.selectNext() } }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        Button("Previous Conversation") { Task { await model.browser.selectPrevious() } }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
    }
}
