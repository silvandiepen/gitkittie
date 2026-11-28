import Foundation
import GitKittieKit

// What the review screens say about actions, assignment, due dates and browser checks, worked
// out once here so the Mac and the iPhone say the same thing and it is tested (GITKITTIE-135,
// GITKITTIE-136). Nothing here writes: the writes are `AppModel+ReviewActions` and
// `AppModel+ReviewAssignment`.

// MARK: - Actions in words

extension ReviewOutcome {
    /// "Accept", "Changes", "Reject": the decision a "When decided" line starts with.
    public var shortTitle: String {
        switch self {
        case .accept: return "Accept"
        case .changes: return "Changes"
        case .reject: return "Reject"
        }
    }
}

/// One line of a request's "When decided" section: "Accept → move PETS-1 to Testing".
public struct ReviewActionLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var outcome: ReviewOutcome
    /// `nil` for the request's own actions; an item or check id otherwise.
    public var entry: String?
    public var card: String
    /// The lane by name, or what the request says when it names no lane of the board.
    public var lane: String
    /// `false` when `to` names no lane of the board: the action will be skipped.
    public var laneFound: Bool
    /// "Accept → move PETS-1 to Testing".
    public var text: String
    /// "your comments go on the card · assigned to Claude", or `nil`.
    public var detail: String?
    /// The action already ran for this outcome (and was not undone).
    public var ran: Bool
}

/// One entry of a request's `actions_run`, in words.
public struct ReviewActionHistoryLine: Identifiable, Equatable, Sendable {
    /// Its index in `actions_run`: what Undo addresses.
    public var index: Int
    public var run: ActionRun
    /// "Moved PETS-1 to Testing", "PETS-1 was already in Testing", "Skipped PETS-2: …".
    public var text: String
    public var id: Int { index }
    /// Whether Undo may be offered: the action moved the card and was not undone. Whether the
    /// card is still untouched is asked of the board (`AppModel.canUndoReviewAction`).
    public var mayUndo: Bool { run.result == .moved && run.undoneAt == nil && run.from != nil }
}

/// What the banner says after a decision ran a request's actions: what moved (with Undo for
/// eight seconds), what waits for "Move anyway?", and what could not run at all.
public struct ReviewActionBanner: Equatable, Sendable {
    /// How long Undo stays on the banner.
    public static let undoSeconds: TimeInterval = 8

    public var ref: ReviewRef
    /// "Moved PETS-1 to Testing", "PETS-1 already in Testing"; empty when nothing ran.
    public var message: String
    /// The moved cards: what Undo takes back.
    public var undoable: [ReviewActionEntry]
    /// Actions that wait for an answer, each with what to ask.
    public var prompts: [Prompt]
    /// Actions that could not run (card or lane gone): shown in red.
    public var failures: [String]

    public struct Prompt: Identifiable, Equatable, Sendable {
        public var conflict: ReviewActionConflict
        /// "PETS-2 is claimed by herma until 14:00 UTC — Move anyway?"
        public var text: String
        /// "Move Anyway", or "Move" when the outcome changed.
        public var button: String
        public var id: UUID { conflict.id }
    }

    /// Hide by itself after `undoSeconds`, unless something waits for an answer.
    public var autoDismissAfter: TimeInterval? { prompts.isEmpty ? Self.undoSeconds : nil }
    public var isEmpty: Bool { message.isEmpty && prompts.isEmpty && failures.isEmpty }
}

extension AppModel {
    /// The lanes of the board a request belongs to.
    func reviewBoardLanes(for request: ReviewRequest) -> [Lane] {
        if let entry = reviewInbox.first(where: { $0.repoID == request.origin && $0.requests.contains { $0.folder == request.folder } }),
           !entry.lanes.isEmpty {
            return entry.lanes
        }
        return board?.config.lanes ?? []
    }

    /// A lane's name as the board calls it ("testing" → "Testing"); what was written when it
    /// names no lane.
    public func reviewLaneName(_ to: String, for request: ReviewRequest) -> String {
        AgentBoard.lane(to, among: reviewBoardLanes(for: request))?.name ?? to
    }

    /// What deciding the request will do, in words: its own actions, then each check's and each
    /// item's, outcome by outcome.
    public func reviewActionLines(_ request: ReviewRequest) -> [ReviewActionLine] {
        let lanes = reviewBoardLanes(for: request)
        let users = reviewBoardUsers(for: request)
        var lines: [ReviewActionLine] = []
        func add(_ actions: ReviewActions, entry: String?) {
            for outcome in ReviewOutcome.allCases {
                for (index, action) in actions[outcome].enumerated() {
                    let card = action.move ?? request.card ?? "the card"
                    let lane = AgentBoard.lane(action.to, among: lanes)
                    let laneName = lane?.name ?? action.to
                    var detail: [String] = []
                    if action.comment { detail.append("your comments go on the card") }
                    if let assign = action.assign {
                        let name = users.first { $0.id.lowercased() == assign.lowercased() }?.name ?? assign
                        detail.append("assigned to \(name)")
                    }
                    let ran = request.actionsRun.contains {
                        $0.entry == entry && $0.on == outcome && $0.card == card && $0.undoneAt == nil && $0.result != .skipped
                    }
                    lines.append(ReviewActionLine(
                        id: "\(entry ?? "")|\(outcome.rawValue)|\(index)", outcome: outcome, entry: entry, card: card,
                        lane: laneName, laneFound: lane != nil,
                        text: "\(outcome.shortTitle) → move \(card) to \(laneName)",
                        detail: detail.isEmpty ? nil : detail.joined(separator: " · "), ran: ran))
                }
            }
        }
        add(request.actions, entry: nil)
        for check in request.checks { add(check.actions, entry: check.id) }
        for item in request.items { add(item.actions, entry: item.id) }
        return lines
    }

    /// The request's `actions_run`, newest first, in words.
    public func reviewActionHistory(_ request: ReviewRequest) -> [ReviewActionHistoryLine] {
        request.actionsRun.enumerated().reversed().map { index, run in
            let lane = reviewLaneName(run.to, for: request)
            let text: String
            switch run.result {
            case .moved, .undone:
                text = "Moved \(run.card) to \(lane)" + (run.undoneAt != nil || run.result == .undone ? " · undone" : "")
            case .already:
                text = "\(run.card) was already in \(lane)"
            case .skipped:
                text = "Did not move \(run.card) to \(lane)" + (run.reason.map { ": \($0)" } ?? "")
            }
            return ReviewActionHistoryLine(index: index, run: run, text: text)
        }
    }

    /// What the banner says for a report.
    public func reviewActionBanner(_ report: ReviewActionReport) -> ReviewActionBanner {
        let request = reviewRequest(report.ref)
        func lane(_ to: String) -> String { request.map { reviewLaneName(to, for: $0) } ?? to }
        var parts: [String] = []
        let moved = report.runs.filter { $0.run.result == .moved }
        if !moved.isEmpty {
            parts.append("Moved " + Self.list(moved.map { "\($0.run.card) to \($0.laneName.isEmpty ? lane($0.run.to) : $0.laneName)" }))
        }
        for entry in report.runs where entry.run.result == .already {
            parts.append("\(entry.run.card) already in \(entry.laneName.isEmpty ? lane(entry.run.to) : entry.laneName)")
        }
        let prompts = report.conflicts.map { conflict -> ReviewActionBanner.Prompt in
            switch conflict.kind {
            case .outcomeChanged:
                return .init(conflict: conflict,
                             text: "Now \(conflict.outcome.title.lowercased()) — move \(conflict.card) to \(lane(conflict.action.to))?",
                             button: "Move")
            case .terminal, .claimed:
                var message = conflict.message
                while message.hasSuffix(".") { message.removeLast() }
                return .init(conflict: conflict, text: "\(message) — Move anyway?", button: "Move Anyway")
            }
        }
        let failures = report.failed.map { entry in
            "Could not move \(entry.run.card.isEmpty ? "the card" : entry.run.card)" + (entry.run.reason.map { ": \($0)" } ?? "")
        }
        return ReviewActionBanner(ref: report.ref, message: parts.joined(separator: " · "), undoable: moved,
                                  prompts: prompts, failures: failures)
    }

    /// Undo every card the banner's actions moved. Returns whether all of them went back.
    @discardableResult
    public func undoReviewActions(_ banner: ReviewActionBanner) async -> Bool {
        var all = true
        for entry in banner.undoable.sorted(by: { $0.index > $1.index }) where entry.index >= 0 {
            if !(await undoReviewAction(banner.ref, index: entry.index)) { all = false }
        }
        return all
    }
}

// MARK: - Assignment

extension AppModel {
    /// The names of the people a request is for (`for:`), as the board calls them; empty for
    /// everyone.
    public func reviewAssigneeNames(_ request: ReviewRequest) -> [String] {
        let users = reviewBoardUsers(for: request)
        return request.assignedTo.map { id in users.first { $0.id.lowercased() == id.lowercased() }?.name ?? id }
    }

    /// "For Sil", "For Sil and Herma", or `nil` for a request for everyone.
    public func reviewForLabel(_ request: ReviewRequest) -> String? {
        let names = reviewAssigneeNames(request)
        return names.isEmpty ? nil : "For \(Self.list(names))"
    }

    /// "Reviewing as Sil": who decisions on this request are recorded as.
    public func reviewingAs(_ request: ReviewRequest) -> String {
        guard let key = reviewBoardKey(for: request) else { return reviewerID(for: request) }
        return reviewingAs(boardKey: key)
    }

    /// The boards that ask "Which one are you?": your login matches none of their users, you
    /// have not answered there, and they have requests for named people.
    public var boardsAskingWhoYouAre: [BoardReviews] {
        reviewInbox.filter { needsReviewIdentity(boardKey: $0.id) }
    }

    /// Why a decision can't be made here, for a disabled button's help: "For Herma. You can comment."
    public func decisionBlockedReason(_ request: ReviewRequest) -> String? { readOnlyNotice(request) }
}

// MARK: - Due dates

/// A request's due date in words: "Due tomorrow", "Due 3 days ago" (overdue).
public struct ReviewDueLabel: Equatable, Sendable {
    public var text: String
    /// The day has passed and something still waits.
    public var overdue: Bool
    /// Today or tomorrow.
    public var soon: Bool
}

public enum ReviewDue {
    /// The day `due` names (`YYYY-MM-DD`, or a timestamp starting with one), at its start in
    /// `calendar`'s time zone.
    public static func day(_ due: String, calendar: Calendar = .current) -> Date? {
        let text = due.trimmingCharacters(in: .whitespaces)
        guard text.count >= 10 else { return nil }
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// `done`: nothing waits any more, so a passed day is not overdue.
    public static func label(_ due: String, done: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> ReviewDueLabel? {
        guard let day = day(due, calendar: calendar),
              let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day else { return nil }
        let text: String
        switch days {
        case 0: text = "Due today"
        case 1: text = "Due tomorrow"
        case 2...6: text = "Due in \(days) days"
        case -1: text = "Due yesterday"
        case ..<(-1): text = "Due \(-days) days ago"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_GB")
            formatter.dateFormat = calendar.component(.year, from: day) == calendar.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
            text = "Due \(formatter.string(from: day))"
        }
        return ReviewDueLabel(text: text, overdue: !done && days < 0, soon: !done && (0...1).contains(days))
    }
}

extension ReviewRequest {
    /// The due date in words, overdue only while something still waits.
    public func dueLabel(now: Date = Date(), calendar: Calendar = .current) -> ReviewDueLabel? {
        due.flatMap { ReviewDue.label($0, done: summary.pending == 0, now: now, calendar: calendar) }
    }

    /// Something in it redoes an earlier entry (`revises`): the request is a later round.
    public var isLaterRound: Bool {
        items.contains { $0.revises != nil } || checks.contains { $0.revises != nil }
    }
}

extension AppModel {
    /// The order the review lists use: requests that still wait and have a due date first, the
    /// soonest on top; then everything else newest first.
    public nonisolated static func inboxOrder(_ requests: [ReviewRequest]) -> [ReviewRequest] {
        let newest = newestFirst(requests)
        let dated = newest.enumerated().compactMap { offset, request -> (Int, Date, ReviewRequest)? in
            guard request.summary.pending > 0, let due = request.due, let day = ReviewDue.day(due) else { return nil }
            return (offset, day, request)
        }
        let sorted = dated.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2)
        let first = Set(sorted.map(\.ref))
        return sorted + newest.filter { !first.contains($0.ref) }
    }
}

// MARK: - Browser checks

/// One cell of a check's sizes × appearance grid.
public enum CheckCellState: Equatable, Sendable {
    /// Nothing answered at this size yet.
    case untouched
    /// Some lines answered, none failed.
    case partial(answered: Int, total: Int)
    /// Every line answered, none failed or noted.
    case passed
    /// Every line answered, none failed, some noted.
    case noted
    /// At least one line failed.
    case failed(Int)
}

/// One row of the grid: a size, and its cell per appearance (one cell when the check lists none).
public struct CheckGridRow: Identifiable, Equatable, Sendable {
    public var size: CheckSize
    public var cells: [Cell]
    public var id: String { size.id }

    public struct Cell: Identifiable, Equatable, Sendable {
        public var key: String
        public var appearance: CheckAppearance?
        public var state: CheckCellState
        public var id: String { key }
    }
}

extension ReviewCheck {
    public func cellState(_ key: String) -> CheckCellState {
        let answers = results[key]?.answers ?? [:]
        let given = checklist.compactMap { answers[$0.id] }
        let failed = given.filter { $0.result == .fail }.count
        if failed > 0 { return .failed(failed) }
        if given.isEmpty { return .untouched }
        if given.count < checklist.count { return .partial(answered: given.count, total: checklist.count) }
        return given.contains { $0.result == .note } ? .noted : .passed
    }

    /// The sizes × appearance grid, in the check's own order.
    public var grid: [CheckGridRow] {
        effectiveSizes.map { size in
            let appearances: [CheckAppearance?] = appearance.isEmpty ? [nil] : appearance.map { Optional($0) }
            return CheckGridRow(size: size, cells: appearances.map { look in
                let key = ReviewCheck.resultKey(size: size.id, appearance: look)
                return CheckGridRow.Cell(key: key, appearance: look, state: cellState(key))
            })
        }
    }

    /// "Phone", "Phone, dark", or the key itself for a size the check does not list ("custom").
    public func label(forKey key: String) -> String {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        let size = effectiveSizes.first { $0.id == parts[0] }?.label ?? (parts[0] == CheckSize.customID ? "Custom" : parts[0])
        return parts.count > 1 ? "\(size), \(parts[1])" : size
    }

    /// "Phone 3/3 · Tablet 1/3 · Desktop –": how far each size is.
    public var progressLine: String {
        resultKeys.map { key in
            let progress = progress(key)
            return "\(label(forKey: key)) \(progress.answered == 0 ? "–" : "\(progress.answered)/\(progress.total)")"
        }.joined(separator: " · ")
    }

    /// How many of all the cells' lines are answered, of how many.
    public var totalProgress: (answered: Int, total: Int) {
        resultKeys.reduce((0, 0)) { sum, key in
            let progress = progress(key)
            return (sum.0 + progress.answered, sum.1 + progress.total)
        }
    }

    /// What Changes starts with: the failed and noted lines, one per line,
    /// "Phone: The download button shows without scrolling — Below the fold."
    public var changesDraft: String {
        failures.map { failure in
            "\(label(forKey: failure.size)): \(failure.text)" + (failure.note.map { " — \($0)" } ?? "")
        }.joined(separator: "\n")
    }
}

/// Where a check's page is drawn: its size in CSS pixels, the size it takes on screen, and the
/// scale between them. Layout always happens at the true width; only the drawing is smaller.
public struct CheckViewportLayout: Equatable, Sendable {
    /// The viewport the page lays out in, in CSS pixels.
    public var css: CGSize
    /// What it takes on screen, in points.
    public var shown: CGSize
    public var scale: CGFloat
    /// The device's own viewport stands in for the size (a phone shows `phone` at its own width).
    public var isNative: Bool

    public var isScaled: Bool { scale < 0.999 }
    /// "390x844": what the results record.
    public var viewport: String { "\(Int(css.width.rounded()))x\(Int(css.height.rounded()))" }
    /// "75 %".
    public var percent: String { "\(Int((scale * 100).rounded())) %" }
}

public enum CheckViewport {
    /// A size at its exact viewport, drawn smaller when it does not fit `available` (the Mac's
    /// screen, or an iPad). A size without dimensions (`default`) fills `available`.
    public static func fit(_ size: CheckSize, in available: CGSize) -> CheckViewportLayout {
        guard let width = size.width, let height = size.height, width > 0, height > 0 else {
            return CheckViewportLayout(css: available, shown: available, scale: 1, isNative: true)
        }
        let css = CGSize(width: width, height: height)
        let scale = min(1, available.width / css.width, available.height / css.height)
        let shown = CGSize(width: (css.width * scale).rounded(.down), height: (css.height * scale).rounded(.down))
        return CheckViewportLayout(css: css, shown: shown, scale: max(scale, 0.05), isNative: false)
    }

    /// The size a device shows as itself: the one whose width is nearest the screen's, among
    /// those no more than 15 % wider. `nil` when every size is much larger (all scaled).
    public static func nativeSizeID(among sizes: [CheckSize], screenWidth: CGFloat) -> String? {
        let candidates = sizes.filter { size in
            guard let width = size.width else { return true }
            return CGFloat(width) <= screenWidth * 1.15
        }
        return candidates.min { a, b in
            abs(CGFloat(a.width ?? Int(screenWidth)) - screenWidth) < abs(CGFloat(b.width ?? Int(screenWidth)) - screenWidth)
        }?.id
    }

    /// On an iPhone or iPad: the size nearest the device fills the screen at the device's own
    /// viewport (recorded as such); the others at their exact viewport, scaled down to fit when
    /// larger ("Scaled preview").
    public static func device(_ size: CheckSize, among sizes: [CheckSize], available: CGSize) -> CheckViewportLayout {
        if size.width == nil || nativeSizeID(among: sizes, screenWidth: available.width) == size.id {
            return CheckViewportLayout(css: available, shown: available, scale: 1, isNative: true)
        }
        return fit(size, in: available)
    }
}
