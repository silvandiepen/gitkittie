import Foundation
import GitKittieKit

// Reviews for named people (ReviewSpec § 4): a request's `for:` names the board users who
// decide it. The app works out who you are on each board, counts and announces only what is
// for you (or for everyone), lists others' requests only under "Everyone", and keeps those
// read-only: comments yes, decisions and checklist answers no. This is routing, not privacy:
// everyone with the repository can read every request.

/// Which requests the Reviews lists show.
public enum ReviewAssignmentFilter: String, CaseIterable, Sendable, Identifiable {
    /// Requests for you, and requests for everyone.
    case forMe
    /// Every request, others' included (read-only).
    case everyone

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .forMe: return "For Me"
        case .everyone: return "Everyone"
        }
    }
}

extension AppModel {
    static let reviewAssignmentFilterKey = "gitkanban.reviewAssignmentFilter"
    static let reviewIdentitiesKey = "gitkanban.reviewIdentities"

    func loadReviewAssignmentState() {
        if let raw = defaults.string(forKey: Self.reviewAssignmentFilterKey), let filter = ReviewAssignmentFilter(rawValue: raw) {
            reviewAssignmentFilter = filter
        }
        reviewIdentities = defaults.dictionary(forKey: Self.reviewIdentitiesKey) as? [String: String] ?? [:]
    }

    /// The login the app matches against a board's users: the folder server's Tailscale login,
    /// the provider account, or this Mac's user name; without a domain.
    var reviewLogin: String {
        let login = serverLogin ?? connection?.login ?? NSUserName()
        return login.split(separator: "@").first.map(String.init) ?? login
    }

    /// The board user whose `github` or `id` is the login, if any.
    func matchedReviewUser(among users: [User]) -> User? {
        let handle = reviewLogin.lowercased()
        return users.first { $0.github?.lowercased() == handle || $0.id.lowercased() == handle }
    }

    /// Who you are on a board: the user your login matches, else the one you chose there
    /// ("Which one are you?"); `nil` when neither (you then see requests for everyone only).
    func reviewUser(among users: [User], boardKey: String?) -> String? {
        if let user = matchedReviewUser(among: users) { return user.id }
        guard let boardKey, let chosen = reviewIdentities[boardKey], !chosen.isEmpty,
              users.contains(where: { $0.id == chosen }) else { return nil }
        return chosen
    }

    /// The key of the board a request belongs to (`repoID|board folder`).
    func reviewBoardKey(for request: ReviewRequest) -> String? {
        if let entry = reviewInbox.first(where: { $0.repoID == request.origin && $0.requests.contains { $0.folder == request.folder } }) {
            return entry.id
        }
        if let repo = activeRepo, request.origin.isEmpty || request.origin == repo.id, let folder = selectedProject?.folder {
            return "\(repo.id)|\(folder)"
        }
        return nil
    }

    /// The users of the board a request belongs to.
    func reviewBoardUsers(for request: ReviewRequest) -> [User] {
        if let entry = reviewInbox.first(where: { $0.repoID == request.origin && $0.requests.contains { $0.folder == request.folder } }) {
            return entry.users
        }
        return board?.config.users ?? []
    }

    /// Who you are on the board of `request`.
    public func reviewUser(for request: ReviewRequest) -> String? {
        reviewUser(among: reviewBoardUsers(for: request), boardKey: reviewBoardKey(for: request))
    }

    /// Whether a request is for you: it names you in `for`, or names nobody.
    public func isForMe(_ request: ReviewRequest) -> Bool { request.isFor(reviewUser(for: request)) }

    /// Someone else's request: you may comment, not decide.
    public func isReadOnly(_ request: ReviewRequest) -> Bool { !isForMe(request) }

    /// "For Herma. You can comment." on top of someone else's request; `nil` on yours.
    public func readOnlyNotice(_ request: ReviewRequest) -> String? {
        guard isReadOnly(request) else { return nil }
        let users = reviewBoardUsers(for: request)
        let names = request.assignedTo.map { id in users.first { $0.id.lowercased() == id.lowercased() }?.name ?? id }
        return "For \(Self.list(names)). You can comment."
    }

    /// "Sil", "Sil and Herma", "Sil, Herma and Hermio".
    nonisolated static func list(_ names: [String]) -> String {
        names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.joined()
    }

    /// The requests a Reviews list shows under the For me / Everyone filter.
    public func shownReviews(_ requests: [ReviewRequest]) -> [ReviewRequest] {
        reviewAssignmentFilter == .everyone ? requests : requests.filter(isForMe)
    }

    // MARK: Who you are on a board

    /// The humans of a board, to choose from in "Which one are you?".
    public func reviewIdentityCandidates(boardKey: String) -> [User] {
        users(ofBoard: boardKey).filter { ($0.kind ?? "human").lowercased() == "human" }
    }

    /// Whether to ask "Which one are you?" on a board: your login matches none of its users,
    /// you have not answered yet, and it has requests for named people.
    public func needsReviewIdentity(boardKey: String) -> Bool {
        let users = users(ofBoard: boardKey)
        guard matchedReviewUser(among: users) == nil, reviewIdentities[boardKey] == nil else { return false }
        let requests = reviewInbox.first { $0.id == boardKey }?.requests ?? (boardKey == openReviewBoardKey ? reviews : [])
        return requests.contains { !$0.assignedTo.isEmpty }
    }

    /// Say who you are on a board (`nil`: "None of these"). Kept on this device only; the
    /// board's README is shared and is not written.
    public func setReviewIdentity(_ userID: String?, boardKey: String) {
        reviewIdentities[boardKey] = userID ?? ""
        defaults.set(reviewIdentities, forKey: Self.reviewIdentitiesKey)
        refreshReviewOwners()
    }

    /// Forget the answer, so the board asks again.
    public func clearReviewIdentity(boardKey: String) {
        reviewIdentities[boardKey] = nil
        defaults.set(reviewIdentities, forKey: Self.reviewIdentitiesKey)
        refreshReviewOwners()
    }

    /// "Sil", or the login when you are none of the board's users: the Reviews header says
    /// "Reviewing as …" so a wrong mapping shows.
    public func reviewingAs(boardKey: String) -> String {
        let users = users(ofBoard: boardKey)
        guard let id = reviewUser(among: users, boardKey: boardKey) else { return reviewLogin }
        return users.first { $0.id == id }?.name ?? id
    }

    /// The open board's key, when a board is open.
    var openReviewBoardKey: String? {
        guard let repo = activeRepo, let folder = selectedProject?.folder else { return nil }
        return "\(repo.id)|\(folder)"
    }

    private func users(ofBoard key: String) -> [User] {
        if let entry = reviewInbox.first(where: { $0.id == key }) { return entry.users }
        return key == openReviewBoardKey ? board?.config.users ?? [] : []
    }

    /// Tell every board's inbox entry who you are there, so its counts are yours.
    func refreshReviewOwners() {
        for index in reviewInbox.indices {
            reviewInbox[index].me = reviewUser(among: reviewInbox[index].users, boardKey: reviewInbox[index].id)
        }
    }
}
