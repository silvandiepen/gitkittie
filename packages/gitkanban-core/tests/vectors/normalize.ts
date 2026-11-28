// The shape both parsers' results are compared in (Swift: ReviewVectorTests). Absent optional
// values are null, so the JSON says exactly what each side must produce.
import {
  checkFailures,
  checkResultKeys,
  isQuestionAnswered,
  reviewOutcome,
  summarizeReview,
  waitingEntries,
  type ReviewAction,
  type ReviewActions,
  type ReviewRequest,
} from '../../src/index.js'

const action = (a: ReviewAction) => ({ move: a.move ?? null, to: a.to, comment: a.comment, assign: a.assign ?? null })
const actions = (a: ReviewActions) => ({ accept: a.accept.map(action), changes: a.changes.map(action), reject: a.reject.map(action) })

export function normalizeReview(review: ReviewRequest): unknown {
  const summary = summarizeReview(review)
  return {
    id: review.id,
    title: review.title,
    card: review.card ?? null,
    notify: review.notify,
    for: review.for,
    due: review.due ?? null,
    actions: actions(review.actions),
    items: review.items.map((item) => ({ id: item.id, status: item.status, actions: actions(item.actions) })),
    questions: review.questions.map((q) => ({ id: q.id, answered: isQuestionAnswered(q) })),
    checks: review.checks.map((check) => ({
      id: check.id,
      url: check.url,
      title: check.title ?? null,
      note: check.note ?? null,
      sizes: check.sizes.map((s) => ({ id: s.id, label: s.label, width: s.width ?? null, height: s.height ?? null, ua: s.ua })),
      appearance: check.appearance,
      checklist: check.checklist,
      result_keys: checkResultKeys(check),
      results: Object.fromEntries(
        Object.entries(check.results)
          .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
          .map(([key, r]) => [
            key,
            {
              viewport: r.viewport ?? null,
              by: r.by ?? null,
              at: r.at ?? null,
              screenshot: r.screenshot ?? null,
              answers: Object.fromEntries(
                Object.entries(r.answers)
                  .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
                  .map(([line, ans]) => [line, { result: ans.result, note: ans.note ?? null, at: ans.at ?? null }]),
              ),
            },
          ]),
      ),
      status: check.status,
      decided_by: check.decidedBy ?? null,
      decided_at: check.decidedAt ?? null,
      revises: check.revises ?? null,
      comments: check.comments.length,
      actions: actions(check.actions),
      failed: checkFailures(check).map((f) => ({ size: f.size, item: f.item, text: f.text, result: f.result, note: f.note ?? null, screenshot: f.screenshot ?? null })),
    })),
    actions_run: review.actionsRun.map((run) => ({
      on: run.on,
      entry: run.entry ?? null,
      card: run.card,
      from: run.from ?? null,
      to: run.to,
      result: run.result,
      reason: run.reason ?? null,
      by: run.by,
      at: run.at,
      undone_at: run.undoneAt ?? null,
      before: Object.fromEntries(Object.entries(run.before).sort(([a], [b]) => (a < b ? -1 : 1))),
    })),
    outcome: reviewOutcome(review),
    waiting: waitingEntries(review),
    waiting_for: { sil: waitingEntries(review, 'sil'), herma: waitingEntries(review, 'herma'), nobody: waitingEntries(review, null) },
    summary: {
      total: summary.total,
      pending: summary.pending,
      approved: summary.approved,
      rejected: summary.rejected,
      changes_requested: summary.changesRequested,
      awaiting_agent: summary.awaitingAgent,
      questions: summary.questions,
      answered: summary.answered,
      checks: summary.checks,
    },
  }
}
