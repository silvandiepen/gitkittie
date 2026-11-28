import Foundation
import GitKittieKit

// Deciding on the files of a review request, the same on every screen:
//
// - asking for changes says what to change, so Changes is never sent without a comment
//   (one file, a selection, or every waiting file at once);
// - the comments already written in a request can be used again on the next file;
// - the full-screen viewer walks through the files a review screen shows (`ReviewPager`).

public extension ReviewStatus {
    /// Whether this decision is sent with a comment, never on its own: Changes tells the
    /// agent what to change, and a bare "changes requested" leaves it guessing.
    var needsComment: Bool { self == .changesRequested }
}

public enum ReviewDecisionRule {
    /// Shown when a decision that needs a comment arrives without one.
    public static let commentRequired = "Say what to change: asking for changes needs a comment."

    /// Whether a decision can be sent with this comment.
    public static func canSend(_ status: ReviewStatus, comment: String?) -> Bool {
        !status.needsComment || !(comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public extension ReviewRequest {
    /// The comments already written in this request, to use again on the next file: most
    /// recent first, each text once (ignoring case and the space around it). Left out: the
    /// agent's own comments (by `requested_by`), comments that point at a marked-up image (they
    /// are about that one picture), and texts `item` already has.
    func commentSuggestions(excluding item: ReviewItem? = nil, limit: Int = 8) -> [String] {
        struct Written { let date: Date?; let order: Int; let text: String }
        let agent = requestedBy?.lowercased()
        var written: [Written] = []
        var order = 0
        let all = items.flatMap(\.comments) + questions.flatMap(\.comments)
        for comment in all {
            order += 1
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, comment.image == nil, comment.by.lowercased() != agent else { continue }
            written.append(Written(date: Review.reviewDate(comment.at), order: order, text: text))
        }
        let newestFirst = written.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.order > b.order
            }
        }
        var seen = Set((item?.comments ?? []).map { Self.suggestionKey($0.text) })
        var result: [String] = []
        for entry in newestFirst where result.count < limit {
            if seen.insert(Self.suggestionKey(entry.text)).inserted { result.append(entry.text) }
        }
        return result
    }

    private static func suggestionKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The questions and items a review screen shows for a filter, in screen order.
    func shownEntries(for filter: ReviewFilter) -> [ReviewEntry] {
        let hidden = hiddenIDs(for: filter)
        return entries.filter { entry in
            switch entry {
            case .question(let question): return !hidden.questions.contains(question.id)
            case .item(let item): return !hidden.items.contains(item.id)
            }
        }
    }
}

/// The pages of the full-screen viewer: the files a review screen shows, in its order. The
/// ids are fixed when the viewer opens (as the screen fixes what it shows), so a file just
/// decided stays where it is under your thumb; the files themselves are read from the request
/// as it is now.
public struct ReviewPager: Equatable, Sendable {
    public let itemIDs: [String]

    public init(itemIDs: [String]) { self.itemIDs = itemIDs }

    /// The files a review screen shows for `filter`.
    public init(request: ReviewRequest, filter: ReviewFilter) {
        itemIDs = request.shownEntries(for: filter).compactMap { entry in
            if case .item(let item) = entry { return item.id } else { return nil }
        }
    }

    /// The pages in their current state. A file the request no longer has is left out.
    public func items(in request: ReviewRequest) -> [ReviewItem] {
        let byID = Dictionary(request.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return itemIDs.compactMap { byID[$0] }
    }

    /// Where to start: the file asked for when it is a page, else the first that waits, else the first.
    public func start(at id: String?, in request: ReviewRequest) -> String? {
        let pages = items(in: request)
        if let id, pages.contains(where: { $0.id == id }) { return id }
        return pages.first(where: { $0.status == .pending })?.id ?? pages.first?.id
    }

    /// "3 of 41" for the page with `id`.
    public func positionLabel(of id: String, in request: ReviewRequest) -> String {
        let pages = items(in: request)
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return "\(pages.count) files" }
        return "\(index + 1) of \(pages.count)"
    }

    /// The next page that still waits after `id`, wrapping round to the start; `nil` when no
    /// other page waits.
    public func nextWaiting(after id: String?, in request: ReviewRequest) -> String? {
        let entries = items(in: request).map(ReviewEntry.item)
        guard let next = ReviewEntry.nextWaiting(after: id.map { "item:\($0)" }, in: entries) else { return nil }
        let nextID = next.id.hasPrefix("item:") ? String(next.id.dropFirst(5)) : next.id
        return nextID == id ? nil : nextID
    }

    /// How many pages still wait.
    public func waitingCount(in request: ReviewRequest) -> Int {
        items(in: request).filter { $0.status == .pending }.count
    }

    /// Each page's decision, in order: what the progress strip draws.
    public func marks(in request: ReviewRequest) -> [ReviewStatus] {
        items(in: request).map(\.status)
    }
}

/// Decisions that can still be taken back: what the files had before one action (a decision,
/// or picking one option of a group, which rejects the others too).
public struct ReviewUndo: Equatable, Sendable, Identifiable {
    public var ref: ReviewRef
    /// The file the action was on.
    public var itemID: String
    /// What it got.
    public var status: ReviewStatus
    /// What each file the action changed had before.
    public var previous: [String: ReviewStatus]
    public let id = UUID()

    public init(ref: ReviewRef, itemID: String, status: ReviewStatus, previous: [String: ReviewStatus]) {
        self.ref = ref
        self.itemID = itemID
        self.status = status
        self.previous = previous
    }

    /// The undo for an action, from the request before and after it: every file whose
    /// decision changed. `nil` when nothing changed.
    public init?(ref: ReviewRef, itemID: String, status: ReviewStatus, before: ReviewRequest, after: ReviewRequest) {
        let now = Dictionary(after.items.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        var previous: [String: ReviewStatus] = [:]
        for item in before.items where now[item.id] != nil && now[item.id] != item.status {
            previous[item.id] = item.status
        }
        guard !previous.isEmpty else { return nil }
        self.init(ref: ref, itemID: itemID, status: status, previous: previous)
    }

    /// "Approved tile-07".
    public var message: String { "\(status == .changesRequested ? "Asked changes on" : status.title) \(itemID)" }
}

extension AppModel {
    /// Choose one option of a pick-one group: approve it and reject the group's other options
    /// that are not rejected yet (an option approved before included), in one write. An item
    /// outside a group is approved. Returns whether it was written.
    @discardableResult
    public func pick(_ request: ReviewRequest, item: ReviewItem) async -> Bool {
        let others = item.group.map { group in
            request.items.filter { $0.group == group && $0.id != item.id && $0.status != .rejected }
        } ?? []
        guard !others.isEmpty else { return await decide(request, item: item, status: .approved) }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        var edits: [ReviewEdit] = item.status == .approved ? [] : [.decision(item: item.id, status: .approved, by: by, at: at)]
        edits += others.map { .decision(item: $0.id, status: .rejected, by: by, at: at) }
        errorMessage = nil
        await rewriteReview(request, edits)
        return errorMessage == nil
    }

    /// Take an action back: each file it changed gets the decision it had before, in one
    /// write. Not held to the comment rule: a file going back to Changes still carries the
    /// comment it was asked with (comments are never taken out of a request).
    @discardableResult
    public func undo(_ undo: ReviewUndo) async -> Bool {
        guard let request = reviewRequest(undo.ref) else { return false }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        let edits: [ReviewEdit] = request.items.compactMap { item in
            guard let previous = undo.previous[item.id], previous != item.status else { return nil }
            return .decision(item: item.id, status: previous, by: by, at: at)
        }
        guard !edits.isEmpty else { return true }
        errorMessage = nil
        await rewriteReview(request, edits)
        return errorMessage == nil
    }
}
