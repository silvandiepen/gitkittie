import Foundation
import GitKittieKit

// Reviews across every board in the app, not only the open one: the home screen says
// how many are waiting and they can be worked through in one go.

/// One board's review requests.
public struct BoardReviews: Identifiable, Sendable, Equatable {
    public var repoID: String
    public var boardFolder: String
    public var boardName: String
    public var icon: String?
    public var color: String?
    /// The board's users, to record decisions under the reviewer's name there.
    public var users: [User]
    public var requests: [ReviewRequest]

    public var id: String { "\(repoID)|\(boardFolder)" }
    /// Items still waiting for a decision.
    public var pending: Int { requests.reduce(0) { $0 + $1.summary.pending } }
    /// Requests with at least one item waiting.
    public var open: [ReviewRequest] { requests.filter { $0.summary.pending > 0 } }
}

extension AppModel {
    /// Items waiting for a decision, over all boards.
    public var pendingReviewTotal: Int { reviewInbox.reduce(0) { $0 + $1.pending } }

    /// Requests with something waiting, over all boards, in the inbox's order.
    public var openReviewRequests: [ReviewRequest] { reviewInbox.flatMap(\.open) }

    /// Whether any board has review requests at all (decided ones included).
    public var hasReviews: Bool { reviewInbox.contains { !$0.requests.isEmpty } }

    /// Changes whenever a board is added or removed: what the inbox is loaded for.
    public var reviewInboxKey: String {
        addedRepos.flatMap { repo in repo.boards.map { "\(repo.id)|\($0.folder)" } }.joined(separator: "\n")
    }

    /// Reload what review screens show: the open board's requests and the inbox.
    public func refreshReviews() async {
        if board != nil { await loadReviews() }
        await loadReviewInbox()
    }

    /// Load every added board's review requests. Boards are read side by side; one that
    /// cannot be read is left out rather than failing the rest.
    public func loadReviewInbox() async {
        guard !isLoadingReviewInbox else { return }
        isLoadingReviewInbox = true
        defer { isLoadingReviewInbox = false; hasLoadedReviewInbox = true }

        var loaded: [(Int, BoardReviews)] = []
        await withTaskGroup(of: (Int, BoardReviews)?.self) { group in
            var index = 0
            for repo in addedRepos {
                for board in repo.boards {
                    let position = index
                    index += 1
                    guard let source = source(for: repo) else { continue }
                    let repoID = repo.id, boardFolder = board.folder, name = board.name, icon = board.icon, color = board.color
                    group.addTask {
                        let (_, config) = await RemoteBoardStore.loadEffectiveConfig(source: source, folder: boardFolder)
                        guard let folder = Review.reviewFolder(config.reviewPath, projectFolder: boardFolder) else { return nil }
                        let requests = await RemoteBoardStore.loadReviews(source: source, folder: folder).map { request -> ReviewRequest in
                            var request = request
                            request.origin = repoID
                            return request
                        }
                        return (position, BoardReviews(
                            repoID: repoID, boardFolder: boardFolder, boardName: name,
                            icon: icon, color: color, users: config.users, requests: requests))
                    }
                }
            }
            for await result in group { if let result { loaded.append(result) } }
        }
        // Boards with something waiting first, then in sidebar order.
        reviewInbox = loaded.sorted { a, b in
            let ap = a.1.pending > 0, bp = b.1.pending > 0
            return ap != bp ? ap : a.0 < b.0
        }.map(\.1).filter { !$0.requests.isEmpty }
        await reviewInboxDidLoad()
    }
}
