import Foundation
import MailClassifier
import MailCore
import MailStore
import Observation

/// What a cleanup batch does, as the dashboard offers it. Never a permanent delete (MAIL-058).
enum CleanupAction: Hashable {
    case archive
    case trash
    case move(to: String)

    var title: String {
        switch self {
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .move(let folder): "Move to “\(folder)”"
        }
    }
}

/// The cleanup dashboard (GKM-021): what clutters the mailbox, read-only, and batch actions
/// whose preview is exactly what runs (MAIL-058..061). UI-free; the views send intents.
///
/// Looking (analyse, select a group, open samples, preview) never changes anything. A batch runs
/// only after `requestRun` and then `confirmRun` for the same preview; the store checks the
/// latest state again in the step that writes the journal, and refuses when anything previewed
/// has changed. One run is one journal batch and one Undo.
@MainActor
@Observable
final class CleanupModel {
    var options = CleanupOptions()
    private(set) var overview: CleanupOverview?
    private(set) var isAnalysing = false
    private(set) var selectedGroup: CleanupGroupID?
    /// The selected group as it is now.
    private(set) var group: CleanupGroup?
    /// The batch being looked at; nil until you choose an action.
    private(set) var preview: CleanupPreview?
    /// Messages you ticked off in the preview.
    private(set) var excluded: Set<MailMessageID> = []
    /// Set by `requestRun`: the preview waiting for your confirmation.
    private(set) var confirming: CleanupPreview?
    /// What the last run did, for the result line.
    private(set) var lastRun: (run: CleanupRun, title: String)?
    /// Messages that changed between the preview and Run; nothing ran.
    private(set) var changedSincePreview: [CleanupDifference] = []
    /// True while a sample is open in the reader instead of the preview.
    var isReadingSample = false
    /// What went wrong, for a notice.
    var notice: String?

    /// The clock, for tests.
    @ObservationIgnored var now: () -> Date = Date.init

    @ObservationIgnored private var store: MailStore?
    @ObservationIgnored private let actions: MailActions
    @ObservationIgnored private let browser: MailBrowser

    init(actions: MailActions, browser: MailBrowser) {
        self.actions = actions
        self.browser = browser
    }

    func attach(_ store: MailStore) {
        self.store = store
        overview = nil
        clearSelection()
    }

    // MARK: Looking (read-only)

    /// Reads the mailbox again: composition, noisy senders and lists, ended offers, digests and
    /// large messages.
    func analyse() async {
        guard let store, !isAnalysing else { return }
        isAnalysing = true
        defer { isAnalysing = false }
        do {
            overview = try await store.cleanupOverview(options: options, now: now())
            if let selectedGroup { group = try await store.cleanupGroup(selectedGroup, options: options, now: now()) }
        } catch {
            notice = String(describing: error)
        }
    }

    /// Shows a group with its samples. No preview yet: that waits for an action.
    func select(_ id: CleanupGroupID?) async {
        guard id != selectedGroup else { return }
        clearSelection()
        selectedGroup = id
        guard let id, let store else { return }
        do { group = try await store.cleanupGroup(id, options: options, now: now()) } catch { notice = String(describing: error) }
    }

    /// Opens a sample (or any previewed message) in the reader, without marking it read.
    func open(_ message: MessageSummary) async {
        await browser.show(message.id, threadID: message.threadID)
        isReadingSample = true
    }

    // MARK: Preview

    /// The exact scope of an action on the selected group. Your exclusions are kept for
    /// messages still in it.
    func preview(_ action: CleanupAction) async {
        guard let store, let selectedGroup else { return }
        guard let operation = operation(for: action, account: selectedGroup.account) else {
            notice = "This account’s folders aren’t known yet. Wait for the first sync to finish."
            return
        }
        confirming = nil
        changedSincePreview = []
        do {
            let preview = try await store.previewCleanup(selectedGroup, operation: operation, options: options, now: now())
            excluded.formIntersection(Set(preview.included.map(\.id)))
            self.preview = preview
        } catch {
            notice = String(describing: error)
        }
    }

    /// Ticks a previewed message off, or back on.
    func toggleExclusion(_ id: MailMessageID) {
        guard preview?.included.contains(where: { $0.id == id }) == true else { return }
        if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
        confirming = nil
    }

    func setIncludesTransactions(_ include: Bool) async {
        options.includeTransactions = include
        guard let preview else { return }
        await self.preview(action(for: preview.operation))
    }

    /// How many messages running changes.
    var runCount: Int { preview.map { $0.included.filter { !excluded.contains($0.id) }.count } ?? 0 }

    func cancelPreview() {
        preview = nil
        confirming = nil
        excluded = []
        changedSincePreview = []
    }

    // MARK: Running

    /// Asks for confirmation; nothing runs yet.
    func requestRun() {
        guard let preview, runCount > 0 else { return }
        confirming = preview
    }

    func cancelRun() { confirming = nil }

    /// Runs the confirmed preview as one batch with one Undo. When anything previewed changed,
    /// nothing runs and a fresh preview is shown with what changed.
    func confirmRun() async {
        guard let store, let confirmed = confirming, confirmed.id == preview?.id else { return }
        confirming = nil
        let title = "Clean Up: \(action(for: confirmed.operation).title)"
        do {
            let run = try await store.runCleanup(confirmed, excluding: excluded, now: now())
            lastRun = (run, title)
            preview = nil
            excluded = []
            changedSincePreview = []
            await actions.didPerform(run.batch, name: title)
        } catch CleanupError.previewChanged(let differences) {
            changedSincePreview = differences
            await refreshPreview(of: confirmed)
            return
        } catch {
            notice = String(describing: error)
            return
        }
        await analyse()
    }

    /// Edit ▸ Undo for the last run, while it is the newest thing to undo.
    var canUndoLastRun: Bool {
        guard let lastRun, let undo = actions.undoManager else { return false }
        return undo.canUndo && undo.undoActionName == lastRun.title
    }

    func undoLastRun() async {
        guard canUndoLastRun else { return }
        actions.undoManager?.undo()
        await actions.waitForUndo()
        lastRun = nil
        await analyse()
    }

    // MARK: Helpers

    /// The folders an account's messages can be moved to (MAIL-036 order and rules).
    func moveTargets(account: MailAccountID) -> [String] { actions.moveTargets(account: account).map(\.name) }

    private func operation(for action: CleanupAction, account: MailAccountID) -> CleanupOperation? {
        switch action {
        case .archive: actions.archiveFolder(for: account).map { .archive(to: $0.name, createTarget: $0.create) }
        case .trash: actions.trashFolder(for: account).map { .trash(to: $0.name, createTarget: $0.create) }
        case .move(let folder): .move(to: folder)
        }
    }

    private func action(for operation: CleanupOperation) -> CleanupAction {
        switch operation {
        case .archive: .archive
        case .trash: .trash
        case .move(let folder): .move(to: folder)
        }
    }

    private func refreshPreview(of stale: CleanupPreview) async {
        let differences = changedSincePreview
        await preview(action(for: stale.operation))
        changedSincePreview = differences
    }

    private func clearSelection() {
        selectedGroup = nil
        group = nil
        cancelPreview()
        isReadingSample = false
    }
}
