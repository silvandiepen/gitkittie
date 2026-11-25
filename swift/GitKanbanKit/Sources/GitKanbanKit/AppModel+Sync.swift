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
        // A refused write is not put in `errorMessage`: it shows where its actions are
        // (the activity list on iOS, the "Not sent" banner on both apps).
        return sent
    }

    public func retrySync(_ item: OutboxOperation) async {
        do { try await outbox.retry(item.id) } catch { errorMessage = error.localizedDescription }
        await refreshSyncItems()
        await flushOutbox()
    }

    public func retryAllFailedSync() async {
        do {
            for item in failedSyncItems { try await outbox.retry(item.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshSyncItems()
        await flushOutbox()
    }

    /// Give up on a write. The change it carried is lost; reload to see the server's state.
    public func discardSync(_ item: OutboxOperation) async {
        do { try await outbox.discard(item.id) } catch { errorMessage = error.localizedDescription }
        await refreshSyncItems()
        if let project = selectedProject, transientListing == nil { await selectProject(project) }
        await refreshReviews()
    }

    /// What a queued write carries, to show before it is retried or discarded, so nothing
    /// goes without the person seeing what it was.
    public func queuedChange(_ item: OutboxOperation) async -> QueuedChange {
        let content: QueuedChange.Content
        switch item.kind {
        case .delete:
            content = .deletion
        case .write:
            if let data = await outbox.data(for: item) {
                content = String(data: data, encoding: .utf8).map(QueuedChange.Content.text) ?? .binary(bytes: data.count)
            } else {
                content = .missing
            }
        }
        return QueuedChange(operation: item, content: content, edits: await outbox.reviewEdits(for: item) ?? [])
    }
}

/// A queued write as it can be shown: its content and, for a review request, what the
/// reviewer did.
public struct QueuedChange: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        /// The file as the write would leave it.
        case text(String)
        /// A file that is not text (an image), of this many bytes.
        case binary(bytes: Int)
        /// The write removes the file.
        case deletion
        /// Nothing was stored on this device for it.
        case missing
    }

    public var operation: OutboxOperation
    public var content: Content
    /// For a review request: the decisions, answers and comments it carries, which are
    /// what is sent.
    public var edits: [ReviewEdit]

    public var id: String { operation.id }

    /// The reviewer's edits in words, one per line, for showing and copying.
    public var editLines: [String] {
        edits.map { edit in
            let when = Review.timestamp(edit.at)
            switch edit {
            case .decision(let item, let status, let by, _):
                return "\(item): \(status.title) by \(by) at \(when)"
            case .comment(let item, let by, let text, let image, _):
                return "\(item): comment by \(by) at \(when): \(text)" + (image.map { " [\($0)]" } ?? "")
            case .answer(let question, let choices, let other, let by, _):
                return "\(question): answered \((choices + [other].compactMap { $0 }).joined(separator: ", ")) by \(by) at \(when)"
            case .questionComment(let question, let by, let text, _):
                return "\(question): comment by \(by) at \(when): \(text)"
            }
        }
    }
}
