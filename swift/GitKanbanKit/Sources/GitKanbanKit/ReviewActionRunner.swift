import Foundation
import GitKittieKit

// Running a review request's actions (ReviewSpec § 2): when a decision gives a request (or an
// entry) its outcome, the cards its `on_accept` / `on_changes` / `on_reject` name are moved
// through the agent write path (`AgentBoard.updateCard`): the lane is resolved against the
// board's effective config, the card's text keeps every key it has, the move is logged on the
// card under the reviewer's id, and `updated_at` is set. What happened goes to the request's
// `actions_run`, so nobody moves the card again.
//
// Conflicts are not forced: a card in a terminal lane, or claimed by someone other than the
// agent that asked, is skipped and offered back as "Move anyway?".

/// Why an action was not run by itself.
public enum ReviewActionConflictKind: String, Sendable, Equatable {
    /// The card is in a terminal lane (Done).
    case terminal
    /// Someone other than the requester holds an unexpired claim on the card.
    case claimed
    /// The outcome changed after the actions of an earlier outcome ran: the new outcome's
    /// actions are offered, never run by themselves.
    case outcomeChanged
}

/// An action that waits for the reviewer to say "Move anyway".
public struct ReviewActionConflict: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var ref: ReviewRef
    public var outcome: ReviewOutcome
    /// `nil` for the request; an item or check id otherwise.
    public var entry: String?
    public var action: ReviewAction
    public var card: String
    public var kind: ReviewActionConflictKind
    /// "GITKITTIE-131 is claimed by herma until 14:00." — what the banner says before "Move anyway?".
    public var message: String

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// What the actions of one decision did: moved cards (with Undo), conflicts to confirm, and
/// actions that could not run at all.
public struct ReviewActionReport: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var ref: ReviewRef
    /// The request's outcome when the request's own actions ran; `nil` when only entries' did.
    public var outcome: ReviewOutcome?
    /// The runs recorded in `actions_run`.
    public var runs: [ReviewActionEntry]
    public var conflicts: [ReviewActionConflict]

    public var moved: [ReviewActionEntry] { runs.filter { $0.run.result == .moved } }
    /// Runs skipped for a reason "Move anyway" does not fix (card or lane gone): shown in red.
    public var failed: [ReviewActionEntry] {
        runs.filter { entry in entry.run.result == .skipped && !conflicts.contains { $0.card == entry.run.card && $0.entry == entry.run.entry } }
    }

    /// "Accepted · GITKITTIE-131 moved to Testing".
    public var summary: String {
        var parts: [String] = []
        if let outcome { parts.append(outcome.title) }
        for entry in runs where entry.run.result == .moved { parts.append("\(entry.run.card) moved to \(entry.laneName)") }
        for entry in runs where entry.run.result == .already { parts.append("\(entry.run.card) already in \(entry.laneName)") }
        return parts.joined(separator: " · ")
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// One `actions_run` entry the app just wrote.
public struct ReviewActionEntry: Sendable, Equatable {
    /// Its index in the request's `actions_run` (what Undo addresses).
    public var index: Int
    public var run: ActionRun
    /// The lane it went to, by name ("Testing").
    public var laneName: String
}

/// The outcome of running one action, before it is written to `actions_run`.
struct ActionAttempt {
    var run: ActionRun
    var laneName: String = ""
    var conflict: (kind: ReviewActionConflictKind, message: String)?
}

extension AgentBoard {
    /// Run one action of a request as `by` (the reviewer's board id). With `force`, a terminal
    /// lane or someone else's claim does not stop it ("Move anyway"). Never throws: what went
    /// wrong is the run's `reason`.
    func runReviewAction(_ action: ReviewAction, outcome: ReviewOutcome, entry: String?, request: ReviewRequest,
                         by: String, force: Bool = false) async -> ActionAttempt {
        let stamp = Review.timestamp(now())
        func skipped(_ card: String, _ reason: String, from: String? = nil, to: String? = nil) -> ActionAttempt {
            ActionAttempt(run: ActionRun(on: outcome, entry: entry, card: card, from: from, to: to ?? action.to, result: .skipped,
                                         reason: reason, by: by, at: stamp))
        }
        guard let cardID = action.move ?? request.card else {
            return skipped("", "the request names no card to move")
        }
        let shell: Shell
        let found: Found
        let lane: Lane
        do {
            shell = try await self.shell()
            found = try await find(cardID, in: shell)
        } catch {
            return skipped(cardID, "card \(cardID) was not found on this board")
        }
        do {
            lane = try Self.lane(action.to, in: shell.config)
        } catch {
            return skipped(found.id, "\"\(action.to)\" is no longer a lane of this board", from: found.lane.id)
        }
        if found.lane.id == lane.id {
            return ActionAttempt(run: ActionRun(on: outcome, entry: entry, card: found.id, from: found.lane.id, to: lane.id,
                                                result: .already, by: by, at: stamp), laneName: lane.name)
        }
        var overridden: String?
        if found.lane.terminal == true {
            let message = "\(found.id) is already \(found.lane.name)."
            if !force {
                var attempt = skipped(found.id, message, from: found.lane.id, to: lane.id)
                attempt.laneName = lane.name
                attempt.conflict = (.terminal, message)
                return attempt
            }
            overridden = "although it was \(found.lane.name)"
        }
        if let claim = Self.liveClaim(found.text, now: now()), claim.owner.lowercased() != request.requestedBy?.lowercased() {
            let until = claim.expires.map { " until \(Self.clock($0))" } ?? ""
            let message = "\(found.id) is claimed by \(claim.owner)\(until)."
            if !force {
                var attempt = skipped(found.id, message, from: found.lane.id, to: lane.id)
                attempt.laneName = lane.name
                attempt.conflict = (.claimed, message)
                return attempt
            }
            overridden = "although claimed by \(claim.owner)"
        }

        var fields: [(key: String, value: AgentFieldValue)] = []
        if let assign = action.assign { fields.append(("assignee", .string(assign))) }
        if entry == nil, outcome != .reject {
            fields.append(("reviewer", .string(by)))
            fields.append(("review_outcome", .string(outcome == .accept ? "approved" : "changes-requested")))
            fields.append(("review_completed_at", .string(stamp)))
        }
        var before: [String: String?] = [:]
        for (key, _) in fields { before[key] = AgentCardText.value(found.text, key) }

        var activity = "\(outcome.verb) review \(request.id); moved to \(lane.name)"
        if let overridden { activity += " \(overridden)" }
        activity += "."
        if action.comment, let feedback = Self.feedback(request, outcome: outcome, entry: entry) {
            activity += " Feedback: \(feedback)"
        }
        let result = outcome == .accept ? "accepted" : outcome == .changes ? "changes requested" : "rejected"
        do {
            var board = self
            board.now = { [stamp] in Review.reviewDate(stamp) ?? Date() }
            _ = try await board.updateCard(found.fileName, fields: fields, lane: lane.id, activity: activity, agent: by,
                                           message: "chore(tasks): move \(found.id) to \(lane.name.lowercased()) (review \(result))")
        } catch {
            return skipped(found.id, error.localizedDescription, from: found.lane.id, to: lane.id)
        }
        return ActionAttempt(run: ActionRun(on: outcome, entry: entry, card: found.id, from: found.lane.id, to: lane.id,
                                            result: .moved, by: by, at: stamp, before: before), laneName: lane.name)
    }

    /// Take a moved card back: to the lane it came from, with the fields the action changed
    /// restored. Refused when the card moved or changed since (its `updated_at` is not the
    /// action's any more).
    func undoReviewAction(_ run: ActionRun, request: ReviewRequest, by: String) async throws {
        guard run.result == .moved, run.undoneAt == nil, let from = run.from else {
            throw AgentBoardError("This review action did not move a card, or was undone already.")
        }
        let shell = try await self.shell()
        let found = try await find(run.card, in: shell)
        guard found.lane.id == run.to, AgentCardText.value(found.text, "updated_at") == run.at else {
            throw AgentBoardError("\(found.id) changed after the review moved it, so the move can no longer be undone.")
        }
        let fields: [(key: String, value: AgentFieldValue)] = run.before.keys.sorted().map { key in
            (key, (run.before[key] ?? nil).map(AgentFieldValue.string) ?? .null)
        }
        let back = try Self.lane(from, in: shell.config)
        _ = try await updateCard(found.fileName, fields: fields, lane: back.id,
                                 activity: "undid the review action of \(request.id); moved back to \(back.name).", agent: by,
                                 message: "chore(tasks): move \(found.id) back to \(back.name.lowercased()) (review action undone)")
    }

    /// Whether `run` can still be undone: the card is where the action put it, untouched since.
    func canUndoReviewAction(_ run: ActionRun) async -> Bool {
        guard run.result == .moved, run.undoneAt == nil, run.from != nil,
              let shell = try? await self.shell(), let found = try? await find(run.card, in: shell) else { return false }
        return found.lane.id == run.to && AgentCardText.value(found.text, "updated_at") == run.at
    }

    /// An unexpired claim on a card: who holds it and until when.
    static func liveClaim(_ text: String, now: Date) -> (owner: String, expires: Date?)? {
        guard let owner = AgentCardText.value(text, "picked_up_by"), !owner.isEmpty else { return nil }
        let expires = AgentCardText.value(text, "claim_expires_at").flatMap(Review.reviewDate)
        if let expires, expires <= now { return nil }
        return (owner, expires)
    }

    /// "14:00" for today, "30 Nov 14:00" otherwise, in UTC (cards store UTC).
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = Calendar(identifier: .gregorian).isDate(date, inSameDayAs: Date()) ? "HH:mm 'UTC'" : "d MMM HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    /// The comments written with the decisions that make an outcome, quoted, at most 500
    /// characters each: for the request, every counted entry with that decision; for an
    /// entry, that entry's.
    static func feedback(_ request: ReviewRequest, outcome: ReviewOutcome, entry: String?) -> String? {
        let status: ReviewStatus = outcome == .accept ? .approved : outcome == .changes ? .changesRequested : .rejected
        var decided: [(decidedAt: String?, decidedBy: String?, comments: [ReviewComment])] = []
        for item in request.items where item.status == status && (entry == nil ? !request.isPickLoser(item) : item.id == entry) {
            decided.append((item.decidedAt, item.decidedBy, item.comments))
        }
        for check in request.checks where check.status == status && (entry == nil || check.id == entry) {
            decided.append((check.decidedAt, check.decidedBy, check.comments))
        }
        var quotes: [String] = []
        for (at, by, comments) in decided {
            let deciding = comments.filter { $0.at == at && $0.at != "" }
            let chosen = deciding.isEmpty ? comments.last(where: { $0.by == by }).map { [$0] } ?? [] : deciding
            for comment in chosen {
                var text = comment.text.replacingOccurrences(of: "\n", with: " ")
                if text.count > 500 { text = String(text.prefix(500)) + "… (more in the review)" }
                if !quotes.contains("\"\(text)\"") { quotes.append("\"\(text)\"") }
            }
        }
        return quotes.isEmpty ? nil : quotes.joined(separator: " ")
    }

    /// What the actions of a request mean, checked before anything is written (create_review):
    /// the lanes exist, moved cards are on this board, assignees are board users, an item or
    /// check names the card it moves, and a request-level action has a card to move.
    func validate(_ actions: ReviewActions, entry: String?, requestCard: String?, shell: Shell) async throws {
        for outcome in ReviewOutcome.allCases {
            for action in actions[outcome] {
                let what = entry.map { "\(outcome.key) of \"\($0)\"" } ?? outcome.key
                if entry != nil, action.move == nil {
                    throw AgentBoardError("\(what) needs \"move\": the card to move (an item or check moves a card of its own).")
                }
                guard let card = action.move ?? requestCard else {
                    throw AgentBoardError("\(what) moves the request's card, but the request has no \"card\". Give \"card\", or \"move\" on the action.")
                }
                _ = try await find(card, in: shell)
                _ = try Self.lane(action.to, in: shell.config)
                if let assign = action.assign, !shell.config.users.contains(where: { $0.id.lowercased() == assign.lowercased() }) {
                    throw AgentBoardError("\(what): \"assign\" \(assign) is not a user of this board. The users are: \(shell.config.users.map(\.id).joined(separator: ", ")).")
                }
            }
        }
    }
}
