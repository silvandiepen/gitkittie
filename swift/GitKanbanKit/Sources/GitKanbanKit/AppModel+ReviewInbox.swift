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
    /// The board's lanes, to say where a review action moves a card ("move PETS-1 to Testing").
    public var lanes: [Lane] = []
    public var requests: [ReviewRequest]
    /// Who you are on this board (a user id), `nil` when nobody: what is counted as yours.
    public var me: String?

    public var id: String { "\(repoID)|\(boardFolder)" }
    /// Entries waiting for a decision or an answer, in requests for you (or for everyone).
    public var pending: Int { mine.reduce(0) { $0 + $1.summary.pending } }
    /// Requests for you with at least one entry waiting.
    public var open: [ReviewRequest] { mine.filter { $0.summary.pending > 0 } }
    /// Requests for you, or for everyone.
    public var mine: [ReviewRequest] { requests.filter { $0.isFor(me) } }
}

extension AppModel {
    /// Items waiting for a decision, over all boards.
    public var pendingReviewTotal: Int { reviewInbox.reduce(0) { $0 + $1.pending } }

    /// Requests with something waiting, over all boards: those with a due date first, the
    /// soonest on top, then newest first ("Review All" starts with what is due, then with what
    /// was asked last).
    public var openReviewRequests: [ReviewRequest] { Self.inboxOrder(reviewInbox.flatMap(\.open)) }

    /// Requests newest first, by `requested_at`. Ones without a date go last, in the order
    /// they came in.
    public nonisolated static func newestFirst(_ requests: [ReviewRequest]) -> [ReviewRequest] {
        requests.enumerated().sorted { a, b in
            switch (BoardProgress.date(a.element.requestedAt), BoardProgress.date(b.element.requestedAt)) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// When a board's latest waiting request was made, to put the board with the newest on top.
    nonisolated static func newestOpenDate(_ board: BoardReviews) -> Date {
        board.open.compactMap { BoardProgress.date($0.requestedAt) }.max() ?? .distantPast
    }

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
                        let requests = Self.inboxOrder(await RemoteBoardStore.loadReviews(source: source, folder: folder).map { request -> ReviewRequest in
                            var request = request
                            request.origin = repoID
                            return request
                        })
                        return (position, BoardReviews(
                            repoID: repoID, boardFolder: boardFolder, boardName: name,
                            icon: icon, color: color, users: config.users, lanes: config.lanes, requests: requests))

                    }
                }
            }
            for await result in group { if let result { loaded.append(result) } }
        }
        // Boards with something waiting first, the one asked most recently on top, then in
        // sidebar order.
        reviewInbox = loaded.sorted { a, b in
            let ap = a.1.pending > 0, bp = b.1.pending > 0
            if ap != bp { return ap }
            let ad = Self.newestOpenDate(a.1), bd = Self.newestOpenDate(b.1)
            return ad != bd ? ad > bd : a.0 < b.0
        }.map(\.1).filter { !$0.requests.isEmpty }
        refreshReviewOwners()
        await reviewInboxDidLoad()
    }
}
