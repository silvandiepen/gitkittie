import MailCore
import MailStore
import SwiftUI

// Everyday actions in the menus, the toolbar, the row menu and the sidebar (GKM-015). They act on
// the marked rows (⌘A takes every row of the view, GKM-071), or the selected one
// (MailBrowser+Marking), in one step, and every one can be undone with ⌘Z. Shortcuts follow Apple Mail: ⌘⇧U read/unread, ⌘⇧L flag, ⌃⌘A archive; ⌫ moves
// the selection to Trash while the list has focus (a bare ⌫ in the menu would also fire in text
// fields).

/// The Message menu's actions.
struct MessageActionCommands: View {
    let model: AppModel

    var body: some View {
        let targets = model.browser.targets(actingOn: nil)
        let rows = model.browser.loadedRows(of: targets)
        let scope = model.browser.scope
        let actions = model.actions
        Button(rows.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread") {
            let action: MessageAction = rows.contains(where: \.isUnread) ? .markRead : .markUnread
            Task { await actions.perform(action, targets: targets, in: scope) }
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(targets.isEmpty)
        Button(rows.contains(where: \.isFlagged) ? "Unflag" : "Flag") {
            let action: MessageAction = rows.contains(where: \.isFlagged) ? .unflag : .flag
            Task { await actions.perform(action, targets: targets, in: scope) }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(targets.isEmpty)
        Divider()
        Button("Archive") { Task { await actions.perform(.archive, targets: targets, in: scope) } }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(targets.isEmpty)
        Button("Move to Trash") { Task { await actions.trash(targets, in: scope) } }
            .disabled(targets.isEmpty || actions.isTrash(scope))
        if actions.isTrash(scope) {
            Button("Delete Permanently…") { Task { await actions.requestDeletion(targets, in: scope) } }
                .disabled(targets.isEmpty)
        }
        MoveToMenu(model: model, targets: targets)
    }
}

/// Message ▸ Move To: the folders of the accounts the conversations belong to. For a selection
/// with rows not loaded yet, every account's folders: a move only touches that account's mail.
struct MoveToMenu: View {
    let model: AppModel
    let targets: ActionTargets

    var body: some View {
        let loaded = model.browser.loadedRows(of: targets)
        let accounts = loaded.count == targets.count ? Set(loaded.map(\.latest.account)) : Set(model.accounts.map(\.id))
        Menu("Move To") {
            ForEach(Array(accounts).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { account in
                if accounts.count > 1 {
                    Text(model.accounts.first { $0.id == account }?.displayName ?? account.rawValue)
                }
                ForEach(model.actions.moveTargets(account: account), id: \.name) { folder in
                    Button(folder.role == "inbox" ? "Inbox" : folder.path.joined(separator: " / ")) {
                        let scope = model.browser.scope
                        Task { await model.actions.perform(.move(to: folder.name, account: account), targets: targets, in: scope) }
                    }
                }
            }
        }
        .disabled(targets.isEmpty || accounts.allSatisfy { model.actions.moveTargets(account: $0).isEmpty })
    }
}

/// The row's context menu: the same actions for that row (or every marked row with it).
struct MessageActionRowMenu: View {
    @Environment(AppModel.self) private var model
    let rowID: String

    var body: some View {
        let targets = model.browser.targets(actingOn: rowID)
        let rows = model.browser.loadedRows(of: targets)
        let scope = model.browser.scope
        let actions = model.actions
        Button(rows.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread") {
            Task { await actions.perform(rows.contains(where: \.isUnread) ? .markRead : .markUnread, targets: targets, in: scope) }
        }
        Button(rows.contains(where: \.isFlagged) ? "Unflag" : "Flag") {
            Task { await actions.perform(rows.contains(where: \.isFlagged) ? .unflag : .flag, targets: targets, in: scope) }
        }
        Divider()
        Button("Archive") { Task { await actions.perform(.archive, targets: targets, in: scope) } }
        if actions.isTrash(scope) {
            Button("Delete Permanently…") { Task { await actions.requestDeletion(targets, in: scope) } }
        } else {
            Button("Move to Trash") { Task { await actions.trash(targets, in: scope) } }
        }
        MoveToMenu(model: model, targets: targets)
    }
}

/// Archive and Trash in the list's toolbar.
struct MessageActionToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            let targets = model.browser.targets(actingOn: nil)
            let scope = model.browser.scope
            Button {
                Task { await model.actions.perform(.archive, targets: targets, in: scope) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive (⌃⌘A)")
            .disabled(targets.isEmpty)
            Button {
                Task { await model.actions.trash(targets, in: scope) }
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .help(model.actions.isTrash(scope) ? "Delete Permanently" : "Move to Trash (⌫)")
            .disabled(targets.isEmpty)
        }
    }
}

extension View {
    /// ⌫ in the list moves the marked or selected conversations to Trash (in Trash: asks to
    /// delete them permanently).
    func trashOnDelete(_ model: AppModel) -> some View {
        onDeleteCommand {
            let targets = model.browser.targets(actingOn: nil)
            let scope = model.browser.scope
            Task { await model.actions.trash(targets, in: scope) }
        }
    }

    /// Dropping conversations on a provider folder moves them there.
    func movesDroppedConversations(to folder: SyncedFolder, of account: MailAccountID, model: AppModel) -> some View {
        dropDestination(for: String.self) { items, _ in
            let threads = SpaceLook.threadIDs(fromDrop: items)
            guard !threads.isEmpty else { return false }
            let scope = model.browser.scope
            Task {
                await model.actions.perform(.move(to: folder.name, account: account), threads: threads, in: scope)
                model.browser.clearMarks()
            }
            return true
        }
    }

    /// Edit ▸ Undo for actions, the Delete Permanently confirmation, and what an action could
    /// not do. Attached once, to the mail window.
    func mailActionChrome(_ model: AppModel) -> some View {
        modifier(MailActionChrome(model: model))
    }
}

private struct MailActionChrome: ViewModifier {
    let model: AppModel
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        @Bindable var actions = model.actions
        content
            .onAppear {
                model.actions.undoManager = undoManager
                model.senders.undoManager = undoManager
            }
            .onChange(of: undoManager) { _, manager in
                model.actions.undoManager = manager
                model.senders.undoManager = manager
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(get: { actions.deletionToConfirm != nil }, set: { if !$0 { actions.deletionToConfirm = nil } }),
                titleVisibility: .visible,
                presenting: actions.deletionToConfirm
            ) { request in
                // The dialog clears the request as it closes; the button keeps the one it showed.
                Button("Delete Permanently", role: .destructive) { Task { await actions.confirmDeletion(request) } }
                Button("Cancel", role: .cancel) { actions.deletionToConfirm = nil }
            } message: { _ in
                Text("They are removed from the provider’s Trash. The copies in your mail folder stay, and Edit ▸ Undo puts them back.")
            }
            .confirmationDialog(
                actions.trashToConfirm?.question ?? "",
                isPresented: Binding(get: { actions.trashToConfirm != nil }, set: { if !$0 { actions.trashToConfirm = nil } }),
                titleVisibility: .visible,
                presenting: actions.trashToConfirm
            ) { request in
                Button("Move to Trash", role: .destructive) { Task { await actions.confirmTrash(request) } }
                Button("Cancel", role: .cancel) { actions.trashToConfirm = nil }
            } message: { _ in
                Text("Edit ▸ Undo puts them all back.")
            }
            .alert("Couldn’t do that", isPresented: Binding(get: { actions.notice != nil }, set: { if !$0 { actions.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.notice ?? "")
            }
    }

    private var deletionTitle: String {
        let count = model.actions.deletionToConfirm?.count ?? 0
        return count == 1 ? "Delete this message permanently?" : "Delete \(count) messages permanently?"
    }
}
