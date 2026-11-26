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
    /// To the account's Junk (a `Junk` folder created on first use without one): what an Always
    /// Junk rule does with a blocked sender's mail (GKM-072).
    case moveToJunk
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
        case .moveToJunk: "Move to Junk"
        case .move: "Move"
        case .deletePermanently: "Delete"
        }
    }

    /// Takes the messages out of the view they are in: the rows leave and the selection ends.
    var changesLocation: Bool {
        switch self {
        case .archive, .moveToTrash, .moveToJunk, .move, .deletePermanently: true
        case .markRead, .markUnread, .flag, .unflag: false
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
    /// A Move to Trash of many, waiting for the person to confirm it once (GKM-071, MAIL-099).
    var trashToConfirm: TrashRequest?

    struct DeletionRequest: Identifiable {
        let id = UUID()
        var targets: ActionTargets
        var scope: MailScope
        var count: Int
    }

    /// Called after an action, its Undo or Redo changed mail: the counts, badge and spaces
    /// follow at once, like the list (GKM-075). Set by the app model.
    @ObservationIgnored var onMailChanged: (@MainActor () async -> Void)?

    struct TrashRequest: Identifiable {
        let id = UUID()
        var targets: ActionTargets
        var scope: MailScope
        /// "Move 312 conversations to Trash?"
        var question: String { SelectionText.trashQuestion(targets) }
    }

    /// From this many conversations (or messages), Move to Trash asks first (MAIL-099).
    static let trashConfirmationThreshold = 50

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

    /// Acts on whole conversations.
    func perform(_ action: MessageAction, threads threadIDs: [String], in scope: MailScope) async {
        await perform(action, targets: ActionTargets(threads: threadIDs), in: scope)
    }

    /// Acts on what the list's selection covers (``MailBrowser/targets(actingOn:)``): whole
    /// conversations and single messages, in one step and one Undo, through the journal. A
    /// deliberate selection is acted on as chosen: Clean Up's protections (MAIL-059) are for
    /// what it suggests, not for this (MAIL-100).
    func perform(_ action: MessageAction, targets: ActionTargets, in scope: MailScope) async {
        guard let store, !targets.isEmpty else { return }
        do {
            var conversations: [MessageSummary] = []
            for thread in targets.threads { conversations += try await store.thread(thread) }
            let singles = try await store.summaries(of: targets.messages)
            var changes = try await plan(action, messages: conversations, in: scope, wholeThreads: true, store: store)
            changes += try await plan(action, messages: singles, in: scope, wholeThreads: false, store: store)
            await apply(changes, action: action)
        } catch {
            notice = String(describing: error)
        }
    }

    /// Move to Trash for the list (⌫, the toolbar, the menus): in Trash it asks to delete
    /// permanently; for many it asks once first ("Move 312 conversations to Trash?"); otherwise
    /// it moves them at once.
    func trash(_ targets: ActionTargets, in scope: MailScope) async {
        guard !targets.isEmpty else { return }
        if isTrash(scope) {
            await requestDeletion(targets, in: scope)
        } else if targets.count >= Self.trashConfirmationThreshold {
            trashToConfirm = TrashRequest(targets: targets, scope: scope)
        } else {
            await perform(.moveToTrash, targets: targets, in: scope)
        }
    }

    /// `request` is the one the dialog showed: a dialog clears ``trashToConfirm`` as it closes,
    /// before its button's task runs.
    func confirmTrash(_ shown: TrashRequest? = nil) async {
        guard let request = shown ?? trashToConfirm else { return }
        trashToConfirm = nil
        await perform(.moveToTrash, targets: request.targets, in: request.scope)
    }

    /// Acts on single messages (the reader's focused message).
    func perform(_ action: MessageAction, messages: [MessageSummary], in scope: MailScope) async {
        await perform(action, messages: messages, in: scope, wholeThreads: false)
    }

    /// Delete Permanently asks first: what it removes cannot come back from the provider's Trash
    /// (Undo can still put the copy kept on this Mac back).
    func requestDeletion(threads: [String], in scope: MailScope) async {
        await requestDeletion(ActionTargets(threads: threads), in: scope)
    }

    func requestDeletion(_ targets: ActionTargets, in scope: MailScope) async {
        guard let store, isTrash(scope), !targets.isEmpty else { return }
        var count = targets.messages.count
        for thread in targets.threads { count += (try? await store.thread(thread).count) ?? 0 }
        deletionToConfirm = DeletionRequest(targets: targets, scope: scope, count: count)
    }

    /// `request` is the one the dialog showed: a dialog clears ``deletionToConfirm`` as it
    /// closes, before its button's task runs.
    func confirmDeletion(_ shown: DeletionRequest? = nil) async {
        guard let request = shown ?? deletionToConfirm else { return }
        deletionToConfirm = nil
        await perform(.deletePermanently, targets: request.targets, in: request.scope)
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
            await apply(try await plan(action, messages: messages, in: scope, wholeThreads: wholeThreads, store: store), action: action)
        } catch {
            notice = String(describing: error)
        }
    }

    /// Writes the changes as one journal batch (one Undo), sends them, and shows the result:
    /// what left the view leaves the list at once, the selection of many ends, and the list
    /// stays where it was (GKM-071).
    private func apply(_ changes: [MailChange], action: MessageAction) async {
        guard let store else { return }
        guard !changes.isEmpty else {
            notice = Self.nothingToDo(action)
            return
        }
        do {
            guard let batch = try await store.perform(changes) else { return }
            registerUndo(batch, name: action.undoName)
            if action.changesLocation { browser.clearMarks() }
            await browser.reload(keepingPlace: true)
            await sync.actionsQueued(for: batch.accounts)
            await onMailChanged?()
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
        case .moveToJunk:
            // Out of every folder it is in but All Mail, Trash and Junk (as Move to Trash is).
            var changes: [MailChange] = []
            for message in messages {
                guard let junk = junkFolder(for: message.account) else { continue }
                let skipped = Set(roleFolders(of: message.account, roles: ["all", "trash", "junk"]))
                let boxes = try await store.effectiveMailboxes(of: message.id)
                let sources = folder.map { boxes.contains($0) ? [$0] : [] } ?? boxes.subtracting(skipped).sorted()
                for source in sources where source != junk.name {
                    changes.append(MailChange(message.id, .move(from: source, to: junk.name, createTarget: junk.create)))
                }
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

    /// Junk: the \Junk folder (or the one chosen in Settings), else a Junk folder created on
    /// first use, which counts as Junk at once (MAIL-110).
    func junkFolder(for account: MailAccountID) -> (name: String, create: Bool)? {
        guard let folders = sync.folders[account], !folders.isEmpty else { return nil }
        if let junk = folders.first(where: { $0.role == "junk" }) { return (junk.name, false) }
        return ("Junk", true)
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
        await onMailChanged?()
    }

    /// Journal rows written elsewhere without a step in Edit ▸ Undo (active organisation,
    /// GKM-031: undone from its history instead): sent and shown like any action.
    func didWrite(accounts: [MailAccountID]) async {
        await browser.reload(keepingPlace: true)
        await sync.actionsQueued(for: accounts)
        await onMailChanged?()
    }

    /// Writes changes a sender rule decided (GKM-072) as one journal batch, sends and shows
    /// them like any action, without an Undo of its own: the rule's Undo covers it, and a move
    /// of newly arrived mail is the rule's doing, not a step of yours.
    func write(_ changes: [MailChange]) async throws -> MailActionBatch? {
        guard let store, !changes.isEmpty, let batch = try await store.perform(changes) else { return nil }
        await browser.reload(keepingPlace: true)
        await sync.actionsQueued(for: batch.accounts)
        await onMailChanged?()
        return batch
    }

    /// Takes back a batch written by ``write(_:)``; returns its inverse, which takes it back again (Redo).
    func takeBack(_ batch: MailActionBatch) async throws -> MailActionBatch? {
        guard let store else { return nil }
        let inverse = try await store.undo(batch)
        await browser.reload(keepingPlace: true)
        if let inverse { await sync.actionsQueued(for: inverse.accounts) }
        await onMailChanged?()
        return inverse
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
                await self?.browser.reload(keepingPlace: true)
                if let inverse { await self?.sync.actionsQueued(for: inverse.accounts) }
                await self?.onMailChanged?()
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
