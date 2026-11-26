import Foundation

/// The Mac menu bar's commands that have a keyboard shortcut (GITKITTIE-098).
///
/// SwiftUI reads a menu item's `.disabled(…)`, its title and the values its action captures when
/// it syncs that menu: at launch, and again each time the person opens the menu. It does not
/// sync when the model changes. A shortcut uses the last sync, so an item that was disabled at
/// launch (the store still opening) kept its shortcut dead, and one that was enabled acted on
/// what was selected when the menu was last opened. These items therefore stay enabled and ask
/// the model when they run; when they can't act, the reason goes to the alert.
enum MenuCommand: Equatable {
    /// File ▸ New Message (⌘N).
    case newMessage
    /// Message ▸ Reply (⌘R), Reply All (⇧⌘R), Forward (⇧⌘F).
    case answer(AppModel.ComposeAction)
    /// File ▸ Import Messages… (⇧⌘I).
    case importMessages
    /// Edit ▸ Search Mail (⌥⌘F).
    case searchMail
    /// Mailbox ▸ Sync Now (⇧⌘N).
    case syncNow
    /// Message ▸ Mark as Read or Unread (⇧⌘U), Flag (⇧⌘L), Archive (⌃⌘A): the marked
    /// conversations, or the selected one.
    case messageAction
}

extension AppModel {
    /// Why `command` can't run now, in words for the alert; nil when it can.
    func unavailableReason(_ command: MenuCommand) -> String? {
        switch phase {
        case .opening: return "Your mail is still opening. Try again in a moment."
        case .failed: return "Your mail folder couldn’t be opened, so this can’t be done."
        case .ready: break
        }
        switch command {
        case .newMessage:
            return sending == nil ? "Your mail is still opening. Try again in a moment." : nil
        case .answer(let action):
            if sending == nil { return "Your mail is still opening. Try again in a moment." }
            guard openMessage == nil else { return nil }
            return switch action {
            case .reply, .replyAll: "Open a message to reply to it."
            case .forward: "Open a message to forward it."
            }
        case .importMessages:
            return isImporting ? "Messages are still being imported. Try again when that’s done." : nil
        case .searchMail:
            return nil
        case .syncNow:
            guard !sync.isRunning else { return nil }
            return accounts.contains(where: { $0.connection != nil })
                ? "Your accounts aren’t syncing yet. Try again in a moment."
                : "There’s no account to sync. Add one with Mailbox ▸ Add Account…."
        case .messageAction:
            return browser.targets(actingOn: nil).isEmpty ? "Select a conversation first." : nil
        }
    }

    /// For a menu command as it runs: true when it can; otherwise its reason goes to the alert
    /// (`actionError`) and it returns false.
    func canRun(_ command: MenuCommand) -> Bool {
        guard let reason = unavailableReason(command) else { return true }
        actionError = reason
        return false
    }
}

/// What the menu bar can do in a compose window: Send, Attach Files… and Delete Draft….
struct ComposeWindowCommands {
    var canSend: Bool
    var send: @MainActor () -> Void
    var requestAttach: @MainActor () -> Void
    var requestDiscard: @MainActor () -> Void
}

/// The open compose windows' commands, by window (GITKITTIE-098). A focused scene value in the
/// menu bar is only read when the menu syncs (see ``MenuCommand``), so Send (⇧⌘D) pressed in a
/// compose window did nothing, or acted on the window that was in front when the Message menu
/// was last opened. Each compose window registers here instead, and the menu's actions look up
/// the window in front when they run.
@MainActor
final class ComposeWindowDirectory {
    private var entries: [ObjectIdentifier: ComposeWindowCommands] = [:]

    init() {}

    /// Sets, or with nil removes, the commands of `window`.
    func set(_ commands: ComposeWindowCommands?, for window: AnyObject) {
        entries[ObjectIdentifier(window)] = commands
    }

    /// The commands of the window in front, when it is a compose window.
    func commands(inFront window: AnyObject?) -> ComposeWindowCommands? {
        window.flatMap { entries[ObjectIdentifier($0)] }
    }

    /// The number of compose windows registered.
    var count: Int { entries.count }

    /// What Send, Attach Files… and Delete Draft… say when no compose window is in front.
    static let noWindowInFront = "Click in the message you’re writing, then try again."
}
