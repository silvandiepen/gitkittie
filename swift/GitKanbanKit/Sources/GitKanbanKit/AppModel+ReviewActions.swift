import Foundation
import GitKittieKit

// Review actions on the reviewer's device (ReviewSpec § 2.3–2.7): the decision that gives a
// request (or an entry) its outcome also runs that outcome's actions, right after the review
// is written. No extra button: the decision is the confirmation, and `reviewActionReport`
// says exactly what happened, with Undo while the card is untouched and "Move anyway?" for
// what was skipped. Also the browser-check decisions and answers (§ 3), which count toward
// the outcome like files.

extension AppModel {
    // MARK: Browser checks

    /// Decide a browser check. Changes needs a comment, as for a file. Returns whether it was written.
    @discardableResult
    public func decideCheck(_ request: ReviewRequest, check: ReviewCheck, status: ReviewStatus, comment: String? = nil) async -> Bool {
        guard ReviewDecisionRule.canSend(status, comment: comment) else {
            errorMessage = ReviewDecisionRule.commentRequired
            return false
        }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        var edits: [ReviewEdit] = [.checkDecision(check: check.id, status: status, by: by, at: at)]
        if let note = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            edits.append(.checkComment(check: check.id, by: by, text: note, at: at))
        }
        await rewriteReview(request, edits)
        return errorMessage == nil
    }

    /// Answer checklist lines at one size key (`result: nil` takes an answer back), in one
    /// write: a screen collects the answers given within a second and sends them together.
    @discardableResult
    public func answerCheck(_ request: ReviewRequest, check: ReviewCheck, key: String,
                            answers: [(line: String, result: CheckAnswerResult?, note: String?)], viewport: String? = nil) async -> Bool {
        guard !answers.isEmpty else { return true }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        await rewriteReview(request, answers.map {
            .checkAnswer(check: check.id, key: key, line: $0.line, result: $0.result, note: $0.note, viewport: viewport, by: by, at: at)
        })
        return errorMessage == nil
    }

    /// Store a screenshot of a check at one size key (`results/<check>-<key>.png` in the request
    /// folder; a newer one replaces the file, git keeps the old) and record it.
    @discardableResult
    public func saveCheckScreenshot(_ request: ReviewRequest, check: ReviewCheck, key: String, png: Data, viewport: String? = nil) async -> Bool {
        guard !isReadOnly(request) else {
            errorMessage = readOnlyNotice(request)
            return false
        }
        let file = ReviewCheck.screenshotPath(check: check.id, key: key)
        guard let source = reviewSource(for: request), let path = request.assetPath(file) else { return false }
        do {
            try await source.writeData(path: path, data: png, message: "Screenshot \(check.id) at \(key) in review \(request.id)")
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        await rewriteReview(request, [.checkScreenshot(check: check.id, key: key, path: file, viewport: viewport,
                                                       by: reviewerID(for: request), at: ReviewEdit.now())])
        return errorMessage == nil
    }

    /// Comment on a browser check (allowed on someone else's request too).
    public func comment(_ request: ReviewRequest, check: ReviewCheck, text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        await rewriteReview(request, [.checkComment(check: check.id, by: reviewerID(for: request), text: body, at: ReviewEdit.now())])
    }

    // MARK: Actions

    /// The board folder a request belongs to.
    func reviewBoardFolder(for request: ReviewRequest) -> String? {
        if let entry = reviewInbox.first(where: { $0.repoID == request.origin && $0.requests.contains { $0.folder == request.folder } }) {
            return entry.boardFolder
        }
        if request.origin.isEmpty || request.origin == activeRepo?.id { return selectedProject?.folder }
        return nil
    }

    /// The board a request's actions move cards on, written through the same source as the review.
    func reviewActionBoard(for request: ReviewRequest) -> AgentBoard? {
        guard let source = reviewSource(for: request), let folder = reviewBoardFolder(for: request) else { return nil }
        return AgentBoard(source: source, folder: folder)
    }

    /// After a decision was written: run the actions of every entry that just got a decision,
    /// and the request's own when it just got its outcome. Once per outcome: an outcome whose
    /// actions ran already is left alone, and a changed outcome's actions are only offered.
    func runReviewActions(_ request: ReviewRequest, before: ReviewRequest, after: ReviewRequest) async {
        guard after.hasActions, let board = reviewActionBoard(for: request) else { return }
        let by = reviewerID(for: request)
        var attempts: [ActionAttempt] = []
        var conflicts: [ReviewActionConflict] = []

        func plan(_ actions: [ReviewAction], outcome: ReviewOutcome, entry: String?) async {
            guard !actions.isEmpty else { return }
            let earlier = after.actionsRun.filter { $0.entry == entry && $0.undoneAt == nil && $0.result != .skipped }
            if earlier.contains(where: { $0.on == outcome }) { return }
            for action in actions {
                let card = action.move ?? after.card ?? ""
                if !earlier.isEmpty {
                    conflicts.append(ReviewActionConflict(
                        ref: request.ref, outcome: outcome, entry: entry, action: action, card: card, kind: .outcomeChanged,
                        message: "Now: \(outcome.title.lowercased()). Move \(card) to \(action.to)?"))
                    continue
                }
                let attempt = await board.runReviewAction(action, outcome: outcome, entry: entry, request: after, by: by)
                attempts.append(attempt)
                if let conflict = attempt.conflict {
                    conflicts.append(ReviewActionConflict(ref: request.ref, outcome: outcome, entry: entry, action: action,
                                                          card: attempt.run.card, kind: conflict.kind, message: conflict.message))
                }
            }
        }

        for item in after.items {
            guard let old = before.items.first(where: { $0.id == item.id }), old.status != item.status,
                  let outcome = ReviewOutcome(status: item.status) else { continue }
            await plan(item.actions[outcome], outcome: outcome, entry: item.id)
        }
        for check in after.checks {
            guard let old = before.checks.first(where: { $0.id == check.id }), old.status != check.status,
                  let outcome = ReviewOutcome(status: check.status) else { continue }
            await plan(check.actions[outcome], outcome: outcome, entry: check.id)
        }
        var requestOutcome: ReviewOutcome?
        if let outcome = after.outcome, before.outcome != outcome {
            requestOutcome = outcome
            await plan(after.actions[outcome], outcome: outcome, entry: nil)
        }
        guard !attempts.isEmpty || !conflicts.isEmpty else { return }
        let entries = await record(attempts, in: request)
        reviewActionReport = ReviewActionReport(ref: request.ref, outcome: requestOutcome, runs: entries, conflicts: conflicts)
        if entries.contains(where: { $0.run.result == .moved }) { await reloadAfterReviewAction(request) }
    }

    /// Write the attempts to the request's `actions_run` and return them with their indices there.
    private func record(_ attempts: [ActionAttempt], in request: ReviewRequest) async -> [ReviewActionEntry] {
        guard !attempts.isEmpty else { return [] }
        let saving = errorMessage
        await rewriteReview(request, attempts.map { .actionRun($0.run) })
        let fresh = reviewRequest(request.ref)?.actionsRun ?? []
        if errorMessage == nil { errorMessage = saving }
        return attempts.map { attempt in
            let index = fresh.lastIndex { $0.card == attempt.run.card && $0.at == attempt.run.at && $0.on == attempt.run.on && $0.entry == attempt.run.entry }
            return ReviewActionEntry(index: index ?? -1, run: attempt.run, laneName: attempt.laneName)
        }
    }

    /// "Move anyway": run a skipped (or offered) action without the check that stopped it; the
    /// card's activity line says what was overridden. Returns whether the card is now there.
    @discardableResult
    public func moveAnyway(_ conflict: ReviewActionConflict) async -> Bool {
        guard let request = reviewRequest(conflict.ref), let board = reviewActionBoard(for: request) else { return false }
        errorMessage = nil
        let attempt = await board.runReviewAction(conflict.action, outcome: conflict.outcome, entry: conflict.entry, request: request,
                                                  by: reviewerID(for: request), force: true)
        let entries = await record([attempt], in: request)
        var report = reviewActionReport?.ref == conflict.ref ? reviewActionReport! : ReviewActionReport(ref: conflict.ref, outcome: nil, runs: [], conflicts: [])
        report.conflicts.removeAll { $0.id == conflict.id }
        report.runs += entries
        reviewActionReport = report
        if attempt.run.result == .moved { await reloadAfterReviewAction(request) }
        if attempt.run.result == .skipped { errorMessage = attempt.run.reason }
        return attempt.run.result == .moved || attempt.run.result == .already
    }

    /// Whether the action recorded at `index` of a request's `actions_run` can still be undone:
    /// the card is where it put it, and nobody changed the card since.
    public func canUndoReviewAction(_ ref: ReviewRef, index: Int) async -> Bool {
        guard let request = reviewRequest(ref), request.actionsRun.indices.contains(index),
              let board = reviewActionBoard(for: request) else { return false }
        return await board.canUndoReviewAction(request.actionsRun[index])
    }

    /// Undo a review action: the card goes back to the lane it came from, with the fields the
    /// action set restored, and the request records `undone_at`. The decision stays as it is.
    @discardableResult
    public func undoReviewAction(_ ref: ReviewRef, index: Int) async -> Bool {
        guard let request = reviewRequest(ref), request.actionsRun.indices.contains(index),
              let board = reviewActionBoard(for: request) else { return false }
        let run = request.actionsRun[index]
        errorMessage = nil
        do {
            try await board.undoReviewAction(run, request: request, by: reviewerID(for: request))
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        await rewriteReview(request, [.actionUndo(card: run.card, runAt: run.at, at: ReviewEdit.now())])
        if var report = reviewActionReport, report.ref == ref {
            report.runs.removeAll { $0.index == index }
            reviewActionReport = report.runs.isEmpty && report.conflicts.isEmpty ? nil : report
        }
        await reloadAfterReviewAction(request)
        return errorMessage == nil
    }

    /// The banner was closed (or its time ran out).
    public func dismissReviewActionReport() { reviewActionReport = nil }

    /// A card moved on a board that may be on screen: show it.
    private func reloadAfterReviewAction(_ request: ReviewRequest) async {
        guard let folder = reviewBoardFolder(for: request), let repo = activeRepo,
              request.origin.isEmpty || request.origin == repo.id, folder == selectedProject?.folder, let project = selectedProject else { return }
        await selectProject(project)
    }
}
