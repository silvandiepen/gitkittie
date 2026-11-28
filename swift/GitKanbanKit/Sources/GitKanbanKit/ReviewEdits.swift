import Foundation
import GitKittieKit

// What a reviewer did to a review request, kept apart from the file it was done to.
//
// A `review.md` is shared: the agent adds rounds and marks things handled, the reviewer
// decides, answers and comments, and the reviewer can work on more than one device. A
// queued write that carries the whole file as it looked then overwrites everything that
// happened since. So a review write in the outbox carries these edits as well, and when it
// is sent they are applied again onto the file as it is on the server now:
//
// - a comment is added when it is not there yet;
// - a decision or an answer goes in unless the one on the server is newer (then it is left
//   out, superseded), or the agent has already acted on the answer. Times are to the
//   second, so of two changes made in the same second the one applied last wins: the
//   reviewer's later one;
// - nothing else in the file changes.
//
// Every reviewer field carries its own time (`decided_at`, `answered_at`, a comment's
// `at`), so the order in which edits are applied does not matter. That is what lets
// several queued writes to one request be folded into one.

/// One thing a reviewer did to a review request.
public enum ReviewEdit: Codable, Sendable, Equatable, Hashable {
    case decision(item: String, status: ReviewStatus, by: String, at: Date)
    case comment(item: String, by: String, text: String, image: String?, at: Date)
    case answer(question: String, choices: [String], other: String?, by: String, at: Date)
    case questionComment(question: String, by: String, text: String, at: Date)
    /// A browser check's decision.
    case checkDecision(check: String, status: ReviewStatus, by: String, at: Date)
    /// One checklist line answered at one size key (`result: nil` takes it back).
    case checkAnswer(check: String, key: String, line: String, result: CheckAnswerResult?, note: String?, viewport: String?, by: String, at: Date)
    /// A screenshot taken at a size key, already written at `path` in the request folder.
    case checkScreenshot(check: String, key: String, path: String, viewport: String?, by: String, at: Date)
    case checkComment(check: String, by: String, text: String, at: Date)
    /// A review action the app ran (or skipped), appended to `actions_run`.
    case actionRun(ActionRun)
    /// A review action taken back: the `actions_run` entry of `card` made at `runAt` gets `undone_at`.
    case actionUndo(card: String, runAt: String, at: Date)

    /// When it was done, to the second: the precision the file stores.
    public var at: Date {
        switch self {
        case .decision(_, _, _, let at), .comment(_, _, _, _, let at), .answer(_, _, _, _, let at), .questionComment(_, _, _, let at),
             .checkDecision(_, _, _, let at), .checkAnswer(_, _, _, _, _, _, _, let at), .checkScreenshot(_, _, _, _, _, let at),
             .checkComment(_, _, _, let at), .actionUndo(_, _, let at):
            return at
        case .actionRun(let run):
            return Review.reviewDate(run.at) ?? Date(timeIntervalSince1970: 0)
        }
    }

    /// A decision or an answer: what only the people a request is for may do.
    public var isDecision: Bool {
        switch self {
        case .decision, .answer, .checkDecision, .checkAnswer, .checkScreenshot: return true
        case .comment, .questionComment, .checkComment, .actionRun, .actionUndo: return false
        }
    }

    /// What it is, in a few words, for the activity list.
    public var summary: String {
        switch self {
        case .decision(let item, let status, _, _): return "\(status.title.lowercased()) on \(item)"
        case .comment(let item, _, _, _, _): return "comment on \(item)"
        case .answer(let question, _, _, _, _): return "answer to \(question)"
        case .questionComment(let question, _, _, _): return "comment on \(question)"
        case .checkDecision(let check, let status, _, _): return "\(status.title.lowercased()) on \(check)"
        case .checkAnswer(let check, let key, let line, _, _, _, _, _): return "\(line) at \(key) on \(check)"
        case .checkScreenshot(let check, let key, _, _, _, _): return "screenshot at \(key) on \(check)"
        case .checkComment(let check, _, _, _): return "comment on \(check)"
        case .actionRun(let run): return "\(run.result.rawValue) \(run.card) to \(run.to)"
        case .actionUndo(let card, _, _): return "undo the move of \(card)"
        }
    }

    /// The time a new edit is stamped with: now, without the fraction the file cannot hold.
    public static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }
}

/// The outcome of applying edits onto a newer copy of a request.
public struct ReviewMerge: Sendable, Equatable {
    public var text: String
    /// Edits that changed the file.
    public var applied: [ReviewEdit] = []
    /// Edits that were already in the file.
    public var present: [ReviewEdit] = []
    /// Edits left out because the server holds something newer, or no longer has what they were about.
    public var superseded: [ReviewEdit] = []
}

public extension Review {
    /// Apply edits the way the reviewer made them: every check of the single-edit calls
    /// holds, and the first edit that cannot be made throws.
    static func apply(_ text: String, edits: [ReviewEdit]) throws -> String {
        try edits.reduce(text) { text, edit in
            switch edit {
            case .decision(let item, let status, let by, let at):
                return try applyDecision(text, itemID: item, status: status, by: by, at: at)
            case .comment(let item, let by, let body, let image, let at):
                return try appendComment(text, itemID: item, by: by, body: body, image: image, at: at)
            case .answer(let question, let choices, let other, let by, let at):
                return try applyAnswer(text, questionID: question, choices: choices, other: other, by: by, at: at)
            case .questionComment(let question, let by, let body, let at):
                return try appendQuestionComment(text, questionID: question, by: by, body: body, at: at)
            case .checkDecision(let check, let status, let by, let at):
                return try applyCheckDecision(text, checkID: check, status: status, by: by, at: at)
            case .checkAnswer(let check, let key, let line, let result, let note, let viewport, let by, let at):
                return try applyCheckAnswer(text, checkID: check, key: key, line: line, result: result, note: note, viewport: viewport, by: by, at: at)
            case .checkScreenshot(let check, let key, let path, let viewport, let by, let at):
                return try applyCheckScreenshot(text, checkID: check, key: key, path: path, viewport: viewport, by: by, at: at)
            case .checkComment(let check, let by, let body, let at):
                return try appendCheckComment(text, checkID: check, by: by, body: body, at: at)
            case .actionRun(let run):
                return try appendActionRun(text, run)
            case .actionUndo(let card, let runAt, let at):
                let request = parse(text, folder: "")
                guard let index = request.actionsRun.firstIndex(where: { $0.card == card && $0.at == runAt }) else {
                    throw ReviewError.actionRunNotFound(-1)
                }
                return try markActionRunUndone(text, index: index, at: at)
            }
        }
    }

    /// Apply edits onto a copy of the request that may have changed since they were made.
    /// Throws only when the file is not a review request any more.
    static func merge(_ text: String, edits: [ReviewEdit]) throws -> ReviewMerge {
        guard BoardMarkdown.splitFrontmatter(text).0 != nil else { throw ReviewError.malformed }
        var result = ReviewMerge(text: text)
        for edit in edits {
            let request = parse(result.text, folder: "")
            switch mergeOutcome(edit, in: request) {
            case .present:
                result.present.append(edit)
            case .superseded:
                result.superseded.append(edit)
            case .apply:
                do {
                    result.text = try apply(result.text, edits: [edit])
                    result.applied.append(edit)
                } catch {
                    // The request no longer allows it (an option was taken away, say).
                    result.superseded.append(edit)
                }
            }
        }
        return result
    }

    /// What a reviewer's edits were, read back from a whole copy of the file. For writes
    /// queued before the outbox kept edits: every decision, answer and comment in the copy
    /// that carries a time. Applied with `merge`, the ones already on the server change
    /// nothing, and the server's newer ones are kept.
    static func edits(inSnapshot text: String) -> [ReviewEdit] {
        guard BoardMarkdown.splitFrontmatter(text).0 != nil else { return [] }
        let request = parse(text, folder: "")
        var edits: [ReviewEdit] = []
        for item in request.items {
            if item.status != .pending, let at = reviewDate(item.decidedAt) {
                edits.append(.decision(item: item.id, status: item.status, by: item.decidedBy ?? "reviewer", at: at))
            }
            for comment in item.comments {
                guard let at = reviewDate(comment.at) else { continue }
                edits.append(.comment(item: item.id, by: comment.by, text: comment.text, image: comment.image, at: at))
            }
        }
        for question in request.questions {
            if question.isAnswered, let at = reviewDate(question.answeredAt) {
                edits.append(.answer(question: question.id, choices: question.answer, other: question.answerOther,
                                     by: question.answeredBy ?? "reviewer", at: at))
            }
            for comment in question.comments {
                guard let at = reviewDate(comment.at) else { continue }
                edits.append(.questionComment(question: question.id, by: comment.by, text: comment.text, at: at))
            }
        }
        return edits
    }

    /// A time as review files write it (`2026-11-24T15:27:00Z`, with or without a fraction).
    static func reviewDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

private enum MergeOutcome { case apply, present, superseded }

private extension Review {
    static func mergeOutcome(_ edit: ReviewEdit, in request: ReviewRequest) -> MergeOutcome {
        switch edit {
        case .decision(let id, let status, _, let at):
            guard let item = request.items.first(where: { $0.id == id }) else { return .superseded }
            if item.status == status { return .present }
            if handled(item.handledAt, after: at) { return .superseded }
            if let server = reviewDate(item.decidedAt), server > at { return .superseded }
            return .apply
        case .comment(let id, let by, let text, let image, let at):
            guard let item = request.items.first(where: { $0.id == id }) else { return .superseded }
            return item.comments.contains { same($0, by: by, text: text, image: image, at: at) } ? .present : .apply
        case .answer(let id, let choices, let other, _, let at):
            guard let question = request.questions.first(where: { $0.id == id }) else { return .superseded }
            let own = other?.trimmingCharacters(in: .whitespacesAndNewlines)
            let wanted = question.options.map(\.id).filter(choices.contains)
            if question.isAnswered, question.answer == wanted, question.answerOther == (own?.isEmpty == true ? nil : own) { return .present }
            // Once the agent has acted on an answer it is locked (Review.applyAnswer refuses).
            if question.handledAt != nil { return .superseded }
            if let server = reviewDate(question.answeredAt), server > at { return .superseded }
            return .apply
        case .questionComment(let id, let by, let text, let at):
            guard let question = request.questions.first(where: { $0.id == id }) else { return .superseded }
            return question.comments.contains { same($0, by: by, text: text, image: nil, at: at) } ? .present : .apply
        case .checkDecision(let id, let status, _, let at):
            guard let check = request.checks.first(where: { $0.id == id }) else { return .superseded }
            if check.status == status { return .present }
            if handled(check.handledAt, after: at) { return .superseded }
            if let server = reviewDate(check.decidedAt), server > at { return .superseded }
            return .apply
        case .checkAnswer(let id, let key, let line, let result, let note, _, _, let at):
            // Answer by answer: each carries its own time, so two devices' answers merge.
            guard let check = request.checks.first(where: { $0.id == id }) else { return .superseded }
            let current = check.results[key]?.answers[line]
            let wantedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if current?.result == result, result == nil || current?.note == (wantedNote?.isEmpty == true ? nil : wantedNote) { return .present }
            if let server = reviewDate(current?.at), server > at { return .superseded }
            return .apply
        case .checkScreenshot(let id, let key, let path, _, _, _):
            guard let check = request.checks.first(where: { $0.id == id }) else { return .superseded }
            return check.results[key]?.screenshot == path ? .present : .apply
        case .checkComment(let id, let by, let text, let at):
            guard let check = request.checks.first(where: { $0.id == id }) else { return .superseded }
            return check.comments.contains { same($0, by: by, text: text, image: nil, at: at) } ? .present : .apply
        case .actionRun(let run):
            let present = request.actionsRun.contains { $0.card == run.card && $0.at == run.at && $0.on == run.on && $0.entry == run.entry }
            return present ? .present : .apply
        case .actionUndo(let card, let runAt, _):
            guard let run = request.actionsRun.first(where: { $0.card == card && $0.at == runAt }) else { return .superseded }
            return run.undoneAt != nil ? .present : .apply
        }
    }

    /// Whether the agent acted on this item after the decision was made. A decision made
    /// after the agent's last action is the reviewer's newer word and still goes in; an older
    /// one would land on a state the agent has moved on from (an item it put back to pending
    /// for another look, say). A time that cannot be read counts as after, the safe side.
    static func handled(_ handledAt: String?, after at: Date) -> Bool {
        guard let handledAt, !handledAt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let handled = reviewDate(handledAt) else { return true }
        return handled > at
    }

    /// Whether a comment in the file is this one: same author, text and image, made at the
    /// same second (or with the same time text, when the file's cannot be read as a time).
    static func same(_ comment: ReviewComment, by: String, text: String, image: String?, at: Date) -> Bool {
        guard comment.by == by,
              comment.text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              comment.image == image else { return false }
        guard let written = reviewDate(comment.at) else { return comment.at == timestamp(at) }
        return abs(written.timeIntervalSince(at)) < 1
    }
}
