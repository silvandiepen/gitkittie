import MailCore
import MailStore
import SwiftUI

// Everyday actions in the menus, the toolbar, the row menu and the sidebar (GKM-015). They act on
// the marked conversations, or the selected one (MailBrowser+Marking), and every one can be
// undone with ⌘Z. Shortcuts follow Apple Mail: ⌘⇧U read/unread, ⌘⇧L flag, ⌃⌘A archive; ⌫ moves
// the selection to Trash while the list has focus (a bare ⌫ in the menu would also fire in text
// fields).

/// The Message menu's actions.
struct MessageActionCommands: View {
    let model: AppModel

    var body: some View {
        let threads = model.browser.threadIDs(actingOn: nil)
        let rows = model.browser.rows.filter { threads.contains($0.threadID) }
        let scope = model.browser.scope
        let actions = model.actions
        Button(rows.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread") {
            let action: MessageAction = rows.contains(where: \.isUnread) ? .markRead : .markUnread
            Task { await actions.perform(action, threads: threads, in: scope) }
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .disabled(threads.isEmpty)
        Button(rows.contains(where: \.isFlagged) ? "Unflag" : "Flag") {
            let action: MessageAction = rows.contains(where: \.isFlagged) ? .unflag : .flag
            Task { await actions.perform(action, threads: threads, in: scope) }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .disabled(threads.isEmpty)
        Divider()
        Button("Archive") { Task { await actions.perform(.archive, threads: threads, in: scope) } }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(threads.isEmpty)
        Button("Move to Trash") { Task { await actions.perform(.moveToTrash, threads: threads, in: scope) } }
            .disabled(threads.isEmpty || actions.isTrash(scope))
        if actions.isTrash(scope) {
            Button("Delete Permanently…") { Task { await actions.requestDeletion(threads: threads, in: scope) } }
                .disabled(threads.isEmpty)
        }
        MoveToMenu(model: model, threads: threads)
    }
}

/// Message ▸ Move To: the folders of the account the conversations belong to.
struct MoveToMenu: View {
    let model: AppModel
    let threads: [String]

    var body: some View {
        let accounts = Set(model.browser.rows.filter { threads.contains($0.threadID) }.map(\.latest.account))
        Menu("Move To") {
            ForEach(Array(accounts).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { account in
                if accounts.count > 1 {
                    Text(model.accounts.first { $0.id == account }?.displayName ?? account.rawValue)
                }
                ForEach(model.actions.moveTargets(account: account), id: \.name) { folder in
                    Button(folder.role == "inbox" ? "Inbox" : folder.path.joined(separator: " / ")) {
                        let scope = model.browser.scope
                        Task { await model.actions.perform(.move(to: folder.name, account: account), threads: threads, in: scope) }
                    }
                }
            }
        }
        .disabled(threads.isEmpty || accounts.allSatisfy { model.actions.moveTargets(account: $0).isEmpty })
    }
}

/// The row's context menu: the same actions for that row (or every marked row with it).
struct MessageActionRowMenu: View {
    @Environment(AppModel.self) private var model
    let rowID: String

    var body: some View {
        let threads = model.browser.threadIDs(actingOn: rowID)
        let rows = model.browser.rows.filter { threads.contains($0.threadID) }
        let scope = model.browser.scope
        let actions = model.actions
        Button(rows.contains(where: \.isUnread) ? "Mark as Read" : "Mark as Unread") {
            Task { await actions.perform(rows.contains(where: \.isUnread) ? .markRead : .markUnread, threads: threads, in: scope) }
        }
        Button(rows.contains(where: \.isFlagged) ? "Unflag" : "Flag") {
            Task { await actions.perform(rows.contains(where: \.isFlagged) ? .unflag : .flag, threads: threads, in: scope) }
        }
        Divider()
        Button("Archive") { Task { await actions.perform(.archive, threads: threads, in: scope) } }
        if actions.isTrash(scope) {
            Button("Delete Permanently…") { Task { await actions.requestDeletion(threads: threads, in: scope) } }
        } else {
            Button("Move to Trash") { Task { await actions.perform(.moveToTrash, threads: threads, in: scope) } }
        }
        MoveToMenu(model: model, threads: threads)
    }
}

/// Archive and Trash in the list's toolbar.
struct MessageActionToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            let threads = model.browser.threadIDs(actingOn: nil)
            let scope = model.browser.scope
            Button {
                Task { await model.actions.perform(.archive, threads: threads, in: scope) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive (⌃⌘A)")
            .disabled(threads.isEmpty)
            Button {
                Task {
                    if model.actions.isTrash(scope) {
                        await model.actions.requestDeletion(threads: threads, in: scope)
                    } else {
                        await model.actions.perform(.moveToTrash, threads: threads, in: scope)
                    }
                }
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .help(model.actions.isTrash(scope) ? "Delete Permanently" : "Move to Trash (⌫)")
            .disabled(threads.isEmpty)
        }
    }
}

extension View {
    /// ⌫ in the list moves the marked or selected conversations to Trash (in Trash: asks to
    /// delete them permanently).
    func trashOnDelete(_ model: AppModel) -> some View {
        onDeleteCommand {
            let threads = model.browser.threadIDs(actingOn: nil)
            let scope = model.browser.scope
            Task {
                if model.actions.isTrash(scope) {
                    await model.actions.requestDeletion(threads: threads, in: scope)
                } else {
                    await model.actions.perform(.moveToTrash, threads: threads, in: scope)
                }
            }
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
            .onAppear { model.actions.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in model.actions.undoManager = manager }
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(get: { actions.deletionToConfirm != nil }, set: { if !$0 { actions.deletionToConfirm = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) { Task { await actions.confirmDeletion() } }
                Button("Cancel", role: .cancel) { actions.deletionToConfirm = nil }
            } message: {
                Text("They are removed from the provider’s Trash. The copies in your mail folder stay, and Edit ▸ Undo puts them back.")
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
