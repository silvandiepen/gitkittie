import Foundation
import GitKittieKit

// Sending the outbox and showing what is in it. See `Outbox.swift`.

extension AppModel {
    /// Something is waiting to be sent, or is being sent right now.
    public var hasUnsentChanges: Bool { syncItems.contains { $0.state != .failed } }
    /// Writes the provider refused. They stay until retried or discarded.
    public var failedSyncItems: [OutboxOperation] { syncItems.filter { $0.state == .failed } }

    /// Re-read the outbox from disk (the share extension writes to it too).
    public func refreshSyncItems() async {
        syncItems = await outbox.operations()
        syncReceipts = await outbox.receipts()
    }

    /// A write was just saved: show it and get it on its way.
    func outboxDidChange() {
        Task {
            await refreshSyncItems()
            await flushOutbox()
        }
    }

    /// Send everything that is waiting. Safe to call at any time and from anywhere: only
    /// one flush runs at once, and a missing connection just leaves things waiting.
    /// Returns how many writes went out.
    @discardableResult
    public func flushOutbox() async -> Int {
        guard !isDemo else { return 0 }
        isSyncing = true
        defer { isSyncing = false }
        let repos = addedRepos
        let sent = await outbox.flush(
            resolve: { [weak self] key in
                guard let repo = repos.first(where: { $0.id == key }) else { return nil }
                return await self?.remoteSource(for: repo)
            },
            changed: { [weak self] in await self?.refreshSyncItems() })
        await refreshSyncItems()
        // A refused write must not go unnoticed where there is no activity list to show it.
        if let refused = failedSyncItems.first(where: { $0.attempts == 1 }) {
            errorMessage = "Not sent: " + (refused.note ?? refused.message)
        }
        return sent
    }

    public func retrySync(_ item: OutboxOperation) async {
        await outbox.retry(item.id)
        await refreshSyncItems()
        await flushOutbox()
    }

    public func retryAllFailedSync() async {
        for item in failedSyncItems { await outbox.retry(item.id) }
        await refreshSyncItems()
        await flushOutbox()
    }

    /// Give up on a write. The change it carried is lost; reload to see the server's state.
    public func discardSync(_ item: OutboxOperation) async {
        await outbox.discard(item.id)
        await refreshSyncItems()
        if let project = selectedProject, transientListing == nil { await selectProject(project) }
    }
}
