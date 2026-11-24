import Foundation
import MailCore
import MailStore
import MailSync
import Observation

/// An everyday action, as the menus, toolbar, keyboard and drags ask for it (GKM-015).
enum MessageAction: Equatable {
    case markRead, markUnread, flag, unflag
    case archive
    case moveToTrash
    /// To a folder of one account; messages of other accounts are left alone.
    case move(to: String, account: MailAccountID)
    /// Only from Trash, after a confirmation.
    case deletePermanently

    /// What Edit ▸ Undo says.
    var undoName: String {
        switch self {
        case .markRead: "Mark as Read"
        case .markUnread: "Mark as Unread"
        case .flag: "Flag"
        case .unflag: "Unflag"
        case .archive: "Archive"
        case .moveToTrash: "Move to Trash"
        case .move: "Move"
        case .deletePermanently: "Delete"
        }
    }
}

/// Turns an action on conversations or messages into journal rows, applies them through the
/// store (shown at once, sent by each account's ``ActionReplayer``) and registers Undo
/// (MAIL-034..037). UI-free; the views send intents.
///
/// Which folder an action moves a message out of depends on where the person is: in a folder,
/// that folder; in All Mail or an account, the inbox for Archive, and every folder the message
/// is in (but Trash and All Mail) for Trash.
@MainActor
@Observable
final class MailActions {
    /// What the last action could not do, for a notice.
    var notice: String?
    /// Conversations waiting for the person to confirm Delete Permanently.
    var deletionToConfirm: DeletionRequest?

    struct DeletionRequest: Identifiable {
        let id = UUID()
        var threads: [String]
        var scope: MailScope
        var count: Int
    }

    /// The window's undo manager (Edit ▸ Undo, ⌘Z). Set by the mail window; tests pass their own.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var store: MailStore?
    @ObservationIgnored private let sync: AccountSync
    @ObservationIgnored private let browser: MailBrowser

    init(sync: AccountSync, browser: MailBrowser) {
        self.sync = sync
        self.browser = browser
    }

    func attach(_ store: MailStore) { self.store = store }

    // MARK: Intents

    /// Acts on whole conversations (the list's marked rows, or the selected one).
    func perform(_ action: MessageAction, threads threadIDs: [String], in scope: MailScope) async {
        guard let store, !threadIDs.isEmpty else { return }
        do {
            var messages: [MessageSummary] = []
            for thread in threadIDs { messages += try await store.thread(thread) }
            await perform(action, messages: messages, in: scope, wholeThreads: true)
        } catch {
            notice = String(describing: error)
        }
    }

    /// Acts on single messages (the reader's focused message).
    func perform(_ action: MessageAction, messages: [MessageSummary], in scope: MailScope) async {
        await perform(action, messages: messages, in: scope, wholeThreads: false)
    }

    /// Delete Permanently asks first: what it removes cannot come back from the provider's Trash
    /// (Undo can still put the copy kept on this Mac back).
    func requestDeletion(threads: [String], in scope: MailScope) async {
        guard let store, isTrash(scope), !threads.isEmpty else { return }
        var count = 0
        for thread in threads { count += (try? await store.thread(thread).count) ?? 0 }
        deletionToConfirm = DeletionRequest(threads: threads, scope: scope, count: count)
    }

    func confirmDeletion() async {
        guard let request = deletionToConfirm else { return }
        deletionToConfirm = nil
        await perform(.deletePermanently, threads: request.threads, in: request.scope)
    }

    /// Failed changes go back in the queue.
    func retryFailed(account: MailAccountID) async {
        guard let store else { return }
        do { try await store.retryFailedActions(account: account) } catch { notice = String(describing: error) }
        await sync.actionsQueued(for: [account])
        await browser.reload()
    }

    /// Failed changes are dropped; the provider's state shows.
    func discardFailed(account: MailAccountID) async {
        guard let store else { return }
        do { try await store.discardFailedActions(account: account) } catch { notice = String(describing: error) }
        await sync.actionsQueued(for: [account])
        await browser.reload()
    }

    /// True when the scope is an account's Trash: Delete Permanently is offered there.
    func isTrash(_ scope: MailScope) -> Bool {
        guard case .folder(let account, let name) = scope else { return false }
        return sync.folders[account]?.first { $0.name == name }?.role == "trash"
    }

    /// The folders a message of this account can be moved to, in the provider's order.
    func moveTargets(account: MailAccountID) -> [SyncedFolder] {
        (sync.folders[account] ?? []).filter { $0.role != "all" && $0.role != "flagged" }
    }

    // MARK: Planning

    private func perform(_ action: MessageAction, messages: [MessageSummary], in scope: MailScope, wholeThreads: Bool) async {
        guard let store, !messages.isEmpty else { return }
        do {
            let changes = try await plan(action, messages: messages, in: scope, wholeThreads: wholeThreads, store: store)
            guard !changes.isEmpty else {
                notice = Self.nothingToDo(action)
                return
            }
            guard let batch = try await store.perform(changes) else { return }
            registerUndo(batch, name: action.undoName)
            await sync.actionsQueued(for: batch.accounts)
            await browser.reload()
        } catch {
            notice = String(describing: error)
        }
    }

    func plan(_ action: MessageAction, messages: [MessageSummary], in scope: MailScope, wholeThreads: Bool,
              store: MailStore) async throws -> [MailChange] {
        let folder = scope.folder
        switch action {
        case .markRead:
            return messages.filter(\.isUnread).map { MailChange($0.id, .setSeen(true)) }
        case .markUnread:
            // A conversation reads as unread when its newest message is.
            let targets = wholeThreads ? Self.newestPerThread(messages) : messages
            return targets.filter { !$0.isUnread }.map { MailChange($0.id, .setSeen(false)) }
        case .flag:
            let targets = wholeThreads ? Self.newestPerThread(messages) : messages
            return targets.filter { !$0.isFlagged }.map { MailChange($0.id, .setFlagged(true)) }
        case .unflag:
            return messages.filter(\.isFlagged).map { MailChange($0.id, .setFlagged(false)) }
        case .archive:
            var changes: [MailChange] = []
            for message in messages {
                guard let target = archiveFolder(for: message.account) else { continue }
                let source = folder ?? inbox(of: message.account)
                guard let source, source != target.name else { continue }
                let boxes = try await store.effectiveMailboxes(of: message.id)
                guard boxes.contains(source) else { continue }
                changes.append(MailChange(message.id, .move(from: source, to: target.name, createTarget: target.create)))
            }
            return changes
        case .moveToTrash:
            var changes: [MailChange] = []
            for message in messages {
                guard let trash = trashFolder(for: message.account) else { continue }
                let boxes = try await store.effectiveMailboxes(of: message.id)
                let sources: [String]
                if let folder {
                    sources = boxes.contains(folder) ? [folder] : []
                } else {
                    let skipped = Set(roleFolders(of: message.account, roles: ["all", "trash"]))
                    sources = boxes.subtracting(skipped).sorted()
                }
                for source in sources where source != trash.name {
                    changes.append(MailChange(message.id, .move(from: source, to: trash.name, createTarget: trash.create)))
                }
            }
            return changes
        case .move(let target, let account):
            var changes: [MailChange] = []
            for message in messages where message.account == account {
                let boxes = try await store.effectiveMailboxes(of: message.id)
                guard !boxes.contains(target) else { continue }
                let source: String? = if let folder, boxes.contains(folder) {
                    folder
                } else if let inbox = inbox(of: message.account), boxes.contains(inbox) {
                    inbox
                } else {
                    // The one real folder it is in; with several, the person picks it from a folder view.
                    Self.single(boxes.subtracting(roleFolders(of: message.account, roles: ["all"])))
                }
                if let source { changes.append(MailChange(message.id, .move(from: source, to: target))) }
            }
            return changes
        case .deletePermanently:
            var changes: [MailChange] = []
            for message in messages {
                guard let trash = sync.folders[message.account]?.first(where: { $0.role == "trash" })?.name else { continue }
                let boxes = try await store.effectiveMailboxes(of: message.id)
                if boxes.contains(trash) { changes.append(MailChange(message.id, .deletePermanently(from: trash))) }
            }
            return changes
        }
    }

    // MARK: Folders by role (MAIL-036)

    /// Archive: the account's SPECIAL-USE \Archive folder, else its \All folder (Gmail: All Mail,
    /// where a move out of the inbox removes the Inbox label), else an Archive folder created on
    /// first use.
    func archiveFolder(for account: MailAccountID) -> (name: String, create: Bool)? {
        guard let folders = sync.folders[account], !folders.isEmpty else { return nil }
        if let archive = folders.first(where: { $0.role == "archive" }) { return (archive.name, false) }
        if let all = folders.first(where: { $0.role == "all" }) { return (all.name, false) }
        return ("Archive", true)
    }

    /// Trash: the \Trash folder, else a Trash folder created on first use.
    func trashFolder(for account: MailAccountID) -> (name: String, create: Bool)? {
        guard let folders = sync.folders[account], !folders.isEmpty else { return nil }
        if let trash = folders.first(where: { $0.role == "trash" }) { return (trash.name, false) }
        return ("Trash", true)
    }

    private func inbox(of account: MailAccountID) -> String? {
        sync.folders[account]?.first { $0.role == "inbox" }?.name
    }

    private func roleFolders(of account: MailAccountID, roles: Set<String>) -> [String] {
        (sync.folders[account] ?? []).filter { $0.role.map(roles.contains) == true }.map(\.name)
    }

    /// A batch written elsewhere (the cleanup dashboard, GKM-021): one Undo for all of it, sent
    /// and shown like any action.
    func didPerform(_ batch: MailActionBatch, name: String) async {
        registerUndo(batch, name: name)
        await sync.actionsQueued(for: batch.accounts)
        await browser.reload()
    }

    // MARK: Undo (MAIL-037)

    private func registerUndo(_ batch: MailActionBatch, name: String) {
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        register(Task { batch }, name: name)
        undoManager.endUndoGrouping()
    }

    /// Registers the reversal of `batch` (still being applied, hence a task) with the undo
    /// manager. Undoing applies the inverse and registers the reversal of that, so Redo works.
    private func register(_ batch: Task<MailActionBatch?, Never>, name: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.reverse(batch, name: name) }
        }
        undoManager?.setActionName(name)
    }

    private func reverse(_ batch: Task<MailActionBatch?, Never>, name: String) {
        guard let store else { return }
        let inverse = Task { @MainActor [weak self] () -> MailActionBatch? in
            guard let applied = await batch.value else { return nil }
            do {
                let inverse = try await store.undo(applied)
                if let inverse { await self?.sync.actionsQueued(for: inverse.accounts) }
                await self?.browser.reload()
                return inverse
            } catch {
                self?.notice = String(describing: error)
                return nil
            }
        }
        pendingUndo = inverse
        register(inverse, name: name)
    }

    /// The undo or redo in flight, for tests.
    @ObservationIgnored private(set) var pendingUndo: Task<MailActionBatch?, Never>?

    /// Waits until the last undo or redo is applied, for tests.
    func waitForUndo() async { _ = await pendingUndo?.value }

    // MARK: Helpers

    private static func newestPerThread(_ messages: [MessageSummary]) -> [MessageSummary] {
        Dictionary(grouping: messages, by: \.threadID).values.compactMap { $0.max { $0.date < $1.date } }
    }

    private static func single(_ set: Set<String>) -> String? { set.count == 1 ? set.first : nil }

    private static func nothingToDo(_ action: MessageAction) -> String? {
        switch action {
        case .archive: "These messages aren’t in a folder they can be archived from."
        case .moveToTrash: "These messages are already in Trash."
        case .deletePermanently: "Only messages in Trash can be deleted permanently."
        default: nil
        }
    }
}

/// How an account's queued actions read in the sidebar.
enum ActionStatusText {
    static func line(_ progress: ReplayProgress?) -> String? {
        guard let progress else { return nil }
        let status = progress.status
        if status.failed > 0 {
            return status.failed == 1 ? "1 change couldn’t be applied" : "\(status.failed) changes couldn’t be applied"
        }
        guard status.pending > 0 else { return nil }
        let count = status.pending == 1 ? "1 change" : "\(status.pending) changes"
        if case .offline = progress.activity { return "\(count) waiting until online" }
        return "\(count) waiting to sync"
    }
}
