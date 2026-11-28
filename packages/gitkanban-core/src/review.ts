import { parseFrontmatter, serializeFrontmatter } from './frontmatter.js'
import {
  actionRunRecord,
  hasActions,
  parseActions,
  parseActionsRun,
  type ActionRun,
  type ReviewActions,
  type ReviewOutcome,
} from './review-actions.js'
import { parseCheck, type CheckAnswerResult, type CheckAppearance, type ReviewCheck } from './review-checks.js'
import { bool, ids, num, parseComments, str, type ReviewComment } from './review-values.js'

export * from './review-actions.js'
export * from './review-checks.js'
export type { ReviewComment } from './review-values.js'

/**
 * Review requests — the asset-review contract from
 * `project-assets/Agents/review-workflow.md`.
 *
 * A request is a folder holding a `review.md` (YAML frontmatter + optional notes)
 * and the assets under review. Agents write the request; a reviewer records a
 * decision and comments. Each side owns its own fields, so the two never clobber
 * each other:
 *
 * - agent: top-level fields, and `id/file/preview/kind/group/pick/note/revises`,
 *   `handled_at`, `shipped_to` on items; `id/question/detail/select/other/options`
 *   and `handled_at` on questions
 * - reviewer: `status`, `decided_by`, `decided_at` on items; `answer`,
 *   `answer_other`, `answered_by`, `answered_at` on questions
 * - both: `comments` (append-only)
 *
 * A request holds items (files to judge), questions (choices to make), or both. A
 * question is single choice (`select: one`, at most one answer in all) or multiple
 * choice (`select: many`), optionally with an answer of the reviewer's own (`other`).
 *
 * Every write here re-parses the current text and changes only the reviewer's
 * fields, so unknown keys and the agent's fields round-trip untouched.
 */

export const REVIEW_FILE = 'review.md'

export type ReviewStatus = 'pending' | 'approved' | 'rejected' | 'changes-requested'
export type ReviewKind = 'image' | 'model' | 'audio' | 'animation' | 'video' | 'other'

/**
 * How loudly a request announces itself when it newly needs an answer (`notify:` in the
 * frontmatter). `urgent` is time-sensitive and breaks through Focus, `normal` (the default
 * when absent or unknown) is an ordinary notification, `silent` only counts on the badge
 * and in the Reviews list.
 */
export type ReviewNotify = 'urgent' | 'normal' | 'silent'

export const REVIEW_NOTIFY_LEVELS: readonly ReviewNotify[] = ['urgent', 'normal', 'silent']

export const REVIEW_STATUSES: readonly ReviewStatus[] = ['pending', 'approved', 'rejected', 'changes-requested']
export const REVIEW_KINDS: readonly ReviewKind[] = ['image', 'model', 'audio', 'animation', 'video', 'other']

export interface ReviewItem {
  id: string
  file: string
  preview?: string
  kind: ReviewKind
  group?: string
  pick?: 'one'
  note?: string
  revises?: string
  status: ReviewStatus
  decidedBy?: string
  decidedAt?: string
  comments: ReviewComment[]
  handledAt?: string
  shippedTo?: string
  frames?: number
  fps?: number
  /** What happens to cards when this item is decided; `move` is required here. */
  actions: ReviewActions
}

export type QuestionSelect = 'one' | 'many'

export interface ReviewQuestionOption {
  id: string
  label: string
  /** Markdown: what choosing it means, and what it costs. */
  detail?: string
}

export interface ReviewQuestion {
  id: string
  question: string
  /** Markdown under the question. */
  detail?: string
  select: QuestionSelect
  /** The reviewer may write an answer of their own. */
  other: boolean
  options: ReviewQuestionOption[]
  /** Chosen option ids, in option order; at most one for `select: one`. */
  answer: string[]
  answerOther?: string
  answeredBy?: string
  answeredAt?: string
  comments: ReviewComment[]
  handledAt?: string
}

export interface ReviewRequest {
  id: string
  project?: string
  card?: string
  title: string
  question?: string
  requestedBy?: string
  requestedAt?: string
  /** How loudly the request is announced; `normal` when the frontmatter has no `notify`. */
  notify: ReviewNotify
  /** Board user ids the request is for; empty = everyone. */
  for: string[]
  /** The day it is due, `YYYY-MM-DD`. */
  due?: string
  /** What happens to cards when the request has an outcome. */
  actions: ReviewActions
  items: ReviewItem[]
  questions: ReviewQuestion[]
  /** Browser checks. */
  checks: ReviewCheck[]
  /** What the app did on decisions (append-only). */
  actionsRun: ActionRun[]
  /** Free-form notes below the frontmatter. */
  body: string
}

export interface ReviewSummary {
  /** Items, questions and checks. */
  total: number
  /** Items and checks without a decision and questions without an answer. */
  pending: number
  approved: number
  rejected: number
  changesRequested: number
  /** Decided or answered by the reviewer but not yet acted on by the agent (`handled_at` unset). */
  awaitingAgent: number
  questions: number
  answered: number
  checks: number
}

function parseStatus(value: unknown): ReviewStatus {
  const s = str(value)
  return s && (REVIEW_STATUSES as readonly string[]).includes(s) ? (s as ReviewStatus) : 'pending'
}

/** A `notify:` value; anything missing or unknown is `normal`. */
export function parseNotify(value: unknown): ReviewNotify {
  const s = str(value)?.toLowerCase()
  return s && (REVIEW_NOTIFY_LEVELS as readonly string[]).includes(s) ? (s as ReviewNotify) : 'normal'
}

function parseKind(value: unknown, file: string): ReviewKind {
  const s = str(value)
  if (s && (REVIEW_KINDS as readonly string[]).includes(s)) return s as ReviewKind
  return kindForFile(file)
}

/** Infer a kind from a file extension, for items that omit `kind`. */
export function kindForFile(file: string): ReviewKind {
  const ext = file.toLowerCase().split('.').pop() ?? ''
  if (['png', 'jpg', 'jpeg', 'webp', 'svg', 'heic'].includes(ext)) return 'image'
  if (['usdz', 'glb', 'gltf', 'reality'].includes(ext)) return 'model'
  if (['m4a', 'wav', 'mp3', 'aiff', 'aif', 'caf'].includes(ext)) return 'audio'
  if (ext === 'gif') return 'animation'
  if (['mp4', 'mov', 'm4v'].includes(ext)) return 'video'
  return 'other'
}

function parseItem(value: unknown, index: number): ReviewItem | null {
  if (!value || typeof value !== 'object') return null
  const r = value as Record<string, unknown>
  const file = str(r.file)
  if (!file) return null
  return {
    id: str(r.id) ?? `item-${index + 1}`,
    file,
    preview: str(r.preview),
    kind: parseKind(r.kind, file),
    group: str(r.group),
    pick: str(r.pick) === 'one' ? 'one' : undefined,
    note: str(r.note),
    revises: str(r.revises),
    status: parseStatus(r.status),
    decidedBy: str(r.decided_by),
    decidedAt: str(r.decided_at),
    comments: parseComments(r.comments),
    handledAt: str(r.handled_at),
    shippedTo: str(r.shipped_to),
    frames: num(r.frames),
    fps: num(r.fps),
    actions: parseActions(r),
  }
}

function parseQuestion(value: unknown, index: number): ReviewQuestion | null {
  if (!value || typeof value !== 'object') return null
  const r = value as Record<string, unknown>
  const question = str(r.question)
  if (!question) return null
  const select: QuestionSelect = str(r.select)?.toLowerCase() === 'many' ? 'many' : 'one'
  const options: ReviewQuestionOption[] = (Array.isArray(r.options) ? r.options : []).flatMap((entry, i) => {
    if (entry && typeof entry === 'object') {
      const o = entry as Record<string, unknown>
      const id = str(o.id) ?? `option-${i + 1}`
      return [{ id, label: str(o.label) ?? id, detail: str(o.detail) }]
    }
    // A bare `- iCloud only` is an option whose label is its id.
    const id = str(entry)
    return id ? [{ id, label: id }] : []
  })
  const ids = options.map((o) => o.id)
  const raw = Array.isArray(r.answer) ? r.answer.map(str) : [str(r.answer)]
  let answer = raw.filter((id): id is string => id !== undefined && ids.includes(id))
  if (select === 'one') answer = answer.slice(0, 1)
  const other = bool(r.other)
  return {
    id: str(r.id) ?? `question-${index + 1}`,
    question,
    detail: str(r.detail),
    select,
    other,
    options,
    answer: ids.filter((id) => answer.includes(id)),
    answerOther: other ? str(r.answer_other) : undefined,
    answeredBy: str(r.answered_by),
    answeredAt: str(r.answered_at),
    comments: parseComments(r.comments),
    handledAt: str(r.handled_at),
  }
}

/** Answered: a time, and an option or an own answer. */
export function isQuestionAnswered(question: ReviewQuestion): boolean {
  return question.answeredAt !== undefined && (question.answer.length > 0 || question.answerOther !== undefined)
}

/**
 * Parse a `review.md`. `fallbackId` (usually the request folder name) is used when
 * the frontmatter has no `id`.
 */
export function parseReview(text: string, fallbackId = 'review'): ReviewRequest {
  const { data, body } = parseFrontmatter(text)
  const items = Array.isArray(data.items)
    ? data.items.map(parseItem).filter((item): item is ReviewItem => item !== null)
    : []
  const questions = Array.isArray(data.questions)
    ? data.questions.map(parseQuestion).filter((q): q is ReviewQuestion => q !== null)
    : []
  const checks = Array.isArray(data.checks)
    ? data.checks.map(parseCheck).filter((c): c is ReviewCheck => c !== null)
    : []
  const id = str(data.id) ?? fallbackId
  const due = str(data.due)
  return {
    id,
    project: str(data.project),
    card: str(data.card),
    title: str(data.title) ?? id,
    question: str(data.question),
    requestedBy: str(data.requested_by),
    requestedAt: str(data.requested_at),
    notify: parseNotify(data.notify),
    for: [...new Set(ids(data.for))],
    due: due && /^\d{4}-\d{2}-\d{2}/.test(due) ? due.slice(0, 10) : undefined,
    actions: parseActions(data),
    items,
    questions,
    checks,
    actionsRun: parseActionsRun(data.actions_run),
    body,
  }
}

/**
 * Whether a request is for `user` (a board user id): it names them in `for`, or names nobody.
 * Without a user (identity unknown) only requests for everyone count.
 */
export function isReviewFor(review: Pick<ReviewRequest, 'for'>, user: string | null | undefined): boolean {
  if (review.for.length === 0) return true
  if (!user) return false
  const key = user.toLowerCase()
  return review.for.some((id) => id.toLowerCase() === key)
}

/**
 * What still waits for the reviewer: ids of items and checks without a decision and of
 * questions without an answer (`item:<id>` / `check:<id>` / `question:<id>`, since they may
 * share an id in a hand-written file). Empty when the request needs no answer. With `user`,
 * empty too when the request is for other people (`for`), so a request newly put on
 * someone counts as new for them.
 */
export function waitingEntries(review: ReviewRequest, user?: string | null): string[] {
  if (user !== undefined && !isReviewFor(review, user)) return []
  return [
    ...review.items.filter((item) => item.status === 'pending').map((item) => `item:${item.id}`),
    ...review.checks.filter((check) => check.status === 'pending').map((check) => `check:${check.id}`),
    ...review.questions.filter((question) => !isQuestionAnswered(question)).map((question) => `question:${question.id}`),
  ]
}

export function summarizeReview(review: ReviewRequest): ReviewSummary {
  const summary: ReviewSummary = {
    total: review.items.length + review.checks.length,
    pending: 0,
    approved: 0,
    rejected: 0,
    changesRequested: 0,
    awaitingAgent: 0,
    questions: review.questions.length,
    answered: 0,
    checks: review.checks.length,
  }
  for (const question of review.questions) {
    summary.total += 1
    if (isQuestionAnswered(question)) {
      summary.answered += 1
      if (!question.handledAt) summary.awaitingAgent += 1
    } else {
      summary.pending += 1
    }
  }
  for (const entry of [...review.items, ...review.checks]) {
    if (entry.status === 'pending') summary.pending += 1
    else {
      if (entry.status === 'approved') summary.approved += 1
      if (entry.status === 'rejected') summary.rejected += 1
      if (entry.status === 'changes-requested') summary.changesRequested += 1
      if (!entry.handledAt) summary.awaitingAgent += 1
    }
  }
  return summary
}

/**
 * Whether an item is a losing option of a pick-one group: the group has an approved option
 * and this is not it. Losers may stay pending and never count against the outcome.
 */
export function isPickLoser(review: ReviewRequest, item: ReviewItem): boolean {
  if (!item.group || item.status === 'approved') return false
  const members = review.items.filter((other) => other.group === item.group)
  const pickOne = members.some((other) => other.pick === 'one')
  return pickOne && members.some((other) => other.status === 'approved')
}

/** An item or check is settled when it is decided, or when it is a losing option of a pick. */
export function isItemSettled(review: ReviewRequest, item: ReviewItem): boolean {
  return item.status !== 'pending' || isPickLoser(review, item)
}

/**
 * The request's outcome once every item and check is settled (questions don't count: they
 * have answers, not decisions); `null` before that, and for a request without items and
 * checks. Any changes requested → `changes`; else any rejected (pick-one losers left out)
 * → `reject`; else `accept`.
 */
export function reviewOutcome(review: ReviewRequest): ReviewOutcome | null {
  if (review.items.length + review.checks.length === 0) return null
  if (review.items.some((item) => !isItemSettled(review, item))) return null
  if (review.checks.some((check) => check.status === 'pending')) return null
  const counted = [...review.items.filter((item) => !isPickLoser(review, item)), ...review.checks]
  if (counted.some((entry) => entry.status === 'changes-requested')) return 'changes'
  if (counted.some((entry) => entry.status === 'rejected')) return 'reject'
  return 'accept'
}

/** The outcome a single decision means for that entry's own actions. */
export function outcomeForStatus(status: ReviewStatus): ReviewOutcome | null {
  switch (status) {
    case 'approved':
      return 'accept'
    case 'changes-requested':
      return 'changes'
    case 'rejected':
      return 'reject'
    default:
      return null
  }
}

/** Whether the request, an item or a check declares any action. */
export function reviewHasActions(review: ReviewRequest): boolean {
  return hasActions(review.actions) || review.items.some((i) => hasActions(i.actions)) || review.checks.some((c) => hasActions(c.actions))
}

export class ReviewItemNotFoundError extends Error {
  constructor(readonly itemId: string) {
    super(`No review item with id "${itemId}"`)
    this.name = 'ReviewItemNotFoundError'
  }
}

type RawItem = Record<string, unknown>

function withRawItem(text: string, itemId: string, mutate: (item: RawItem) => void): string {
  const { data, body } = parseFrontmatter(text)
  const items = Array.isArray(data.items) ? (data.items as unknown[]) : []
  const index = items.findIndex(
    (entry, i) => entry && typeof entry === 'object' && (str((entry as RawItem).id) ?? `item-${i + 1}`) === itemId,
  )
  if (index < 0) throw new ReviewItemNotFoundError(itemId)
  mutate(items[index] as RawItem)
  return serializeFrontmatter(data, body)
}

export interface ReviewDecision {
  itemId: string
  status: ReviewStatus
  by: string
  /** ISO-8601 timestamp. */
  at: string
}

/**
 * Record a reviewer decision on one item. Only `status`, `decided_by` and
 * `decided_at` change. Setting `pending` clears the decision.
 */
export function applyReviewDecision(text: string, decision: ReviewDecision): string {
  return withRawItem(text, decision.itemId, (item) => {
    item.status = decision.status
    if (decision.status === 'pending') {
      item.decided_by = null
      item.decided_at = null
    } else {
      item.decided_by = decision.by
      item.decided_at = decision.at
    }
  })
}

export class ReviewQuestionNotFoundError extends Error {
  constructor(readonly questionId: string) {
    super(`No question with id "${questionId}"`)
    this.name = 'ReviewQuestionNotFoundError'
  }
}

export interface ReviewAnswer {
  questionId: string
  /** Chosen option ids. */
  choices: string[]
  /** The reviewer's own answer, where the question allows one. */
  other?: string
  /** Appended to the question's comments when given. */
  comment?: string
  by: string
  /** ISO-8601 timestamp. */
  at: string
}

/**
 * Answer a question, or change the answer while the agent has not acted on it. Only
 * `answer`, `answer_other`, `answered_by` and `answered_at` change (and a comment is
 * appended when given). Checked against the question as the file has it: known option
 * ids only, one choice in all for `select: one`, an own answer only where `other` allows.
 */
export function applyReviewAnswer(text: string, answer: ReviewAnswer): string {
  const { data, body } = parseFrontmatter(text)
  const questions = Array.isArray(data.questions) ? (data.questions as unknown[]) : []
  const index = questions.findIndex(
    (entry, i) => entry && typeof entry === 'object' && (str((entry as RawItem).id) ?? `question-${i + 1}`) === answer.questionId,
  )
  const raw = questions[index] as RawItem | undefined
  const question = raw ? parseQuestion(raw, index) : null
  if (!raw || !question) throw new ReviewQuestionNotFoundError(answer.questionId)
  if (question.handledAt) throw new Error(`The agent has already acted on the answer to "${answer.questionId}"`)
  const known = question.options.map((o) => o.id)
  const unknown = answer.choices.find((id) => !known.includes(id))
  if (unknown !== undefined) throw new Error(`"${unknown}" is not an option of this question`)
  const own = answer.other?.trim() || undefined
  if (own !== undefined && !question.other) throw new Error('This question has no room for an answer of your own')
  const picked = known.filter((id) => answer.choices.includes(id))
  if (picked.length === 0 && own === undefined) throw new Error('Choose an option or write an answer')
  if (question.select === 'one' && picked.length + (own === undefined ? 0 : 1) > 1) {
    throw new Error('This question takes one answer')
  }
  raw.answer = picked
  raw.answer_other = own ?? null
  raw.answered_by = answer.by
  raw.answered_at = answer.at
  const note = answer.comment?.trim()
  if (note) {
    const existing = Array.isArray(raw.comments) ? raw.comments : []
    raw.comments = [...existing, { by: answer.by, at: answer.at, text: note }]
  }
  return serializeFrontmatter(data, body)
}

/** Append a comment to one item. Existing comments are never rewritten. */
export function appendReviewComment(text: string, itemId: string, comment: ReviewComment): string {
  const trimmed = comment.text.trim()
  if (trimmed.length === 0) throw new Error('A review comment needs text')
  return withRawItem(text, itemId, (item) => {
    const existing = Array.isArray(item.comments) ? item.comments : []
    item.comments = [...existing, { by: comment.by, at: comment.at, text: trimmed }]
  })
}

export class ReviewCheckNotFoundError extends Error {
  constructor(readonly checkId: string) {
    super(`No browser check with id "${checkId}"`)
    this.name = 'ReviewCheckNotFoundError'
  }
}

function withRawCheck(text: string, checkId: string, mutate: (check: RawItem) => void): string {
  const { data, body } = parseFrontmatter(text)
  const checks = Array.isArray(data.checks) ? (data.checks as unknown[]) : []
  const index = checks.findIndex(
    (entry, i) => entry && typeof entry === 'object' && (str((entry as RawItem).id) ?? `check-${i + 1}`) === checkId,
  )
  if (index < 0) throw new ReviewCheckNotFoundError(checkId)
  mutate(checks[index] as RawItem)
  return serializeFrontmatter(data, body)
}

/** Decide a browser check, like an item: only `status`, `decided_by`, `decided_at` change. */
export function applyCheckDecision(text: string, decision: { checkId: string; status: ReviewStatus; by: string; at: string }): string {
  return withRawCheck(text, decision.checkId, (check) => {
    check.status = decision.status
    check.decided_by = decision.status === 'pending' ? null : decision.by
    check.decided_at = decision.status === 'pending' ? null : decision.at
  })
}

export interface CheckAnswerEdit {
  checkId: string
  /** The size key: `<size id>` or `<size id>.<appearance>`. */
  key: string
  line: string
  /** `null` takes the answer back. */
  result: CheckAnswerResult | null
  note?: string
  by: string
  at: string
  /** The viewport actually used, `390x844`. */
  viewport?: string
}

/**
 * Answer one checklist line at one size. A `note` answer needs a note. Only that answer and
 * the result's `by` / `at` / `viewport` change.
 */
export function applyCheckAnswer(text: string, edit: CheckAnswerEdit): string {
  const note = edit.note?.trim() || undefined
  if (edit.result === 'note' && !note) throw new Error('A note answer needs the note')
  return withRawCheck(text, edit.checkId, (check) => {
    const lines = parseCheck(check, 0)?.checklist ?? []
    if (!lines.some((line) => line.id === edit.line)) throw new Error(`"${edit.line}" is not a line of check "${edit.checkId}"`)
    const results = (check.results && typeof check.results === 'object' && !Array.isArray(check.results) ? check.results : {}) as RawItem
    const result = (results[edit.key] && typeof results[edit.key] === 'object' ? results[edit.key] : {}) as RawItem
    const answers = (result.answers && typeof result.answers === 'object' ? result.answers : {}) as RawItem
    if (edit.result === null) {
      delete answers[edit.line]
    } else {
      const answer: RawItem = { result: edit.result }
      if (note) answer.note = note
      answer.at = edit.at
      answers[edit.line] = answer
    }
    if (edit.viewport) result.viewport = edit.viewport
    result.by = edit.by
    result.at = edit.at
    result.answers = answers
    results[edit.key] = result
    check.results = results
  })
}

/** Record the screenshot taken at a size (already written to `path` in the request folder). */
export function applyCheckScreenshot(text: string, edit: { checkId: string; key: string; path: string; by: string; at: string }): string {
  return withRawCheck(text, edit.checkId, (check) => {
    const results = (check.results && typeof check.results === 'object' && !Array.isArray(check.results) ? check.results : {}) as RawItem
    const result = (results[edit.key] && typeof results[edit.key] === 'object' ? results[edit.key] : {}) as RawItem
    result.screenshot = edit.path
    result.by = edit.by
    result.at = edit.at
    if (!result.answers) result.answers = {}
    results[edit.key] = result
    check.results = results
  })
}

/** Append a comment to a browser check. Existing comments are never rewritten. */
export function appendCheckComment(text: string, checkId: string, comment: ReviewComment): string {
  const trimmed = comment.text.trim()
  if (trimmed.length === 0) throw new Error('A review comment needs text')
  return withRawCheck(text, checkId, (check) => {
    const existing = Array.isArray(check.comments) ? check.comments : []
    check.comments = [...existing, { by: comment.by, at: comment.at, text: trimmed }]
  })
}

/** Append one entry to the request's `actions_run`. Existing entries are never rewritten. */
export function appendActionRun(text: string, run: ActionRun): string {
  const { data, body } = parseFrontmatter(text)
  const existing = Array.isArray(data.actions_run) ? data.actions_run : []
  data.actions_run = [...existing, actionRunRecord(run)]
  return serializeFrontmatter(data, body)
}

/** Mark the `index`-th `actions_run` entry undone: `undone_at`, and nothing else. */
export function markActionRunUndone(text: string, index: number, at: string): string {
  const { data, body } = parseFrontmatter(text)
  const list = Array.isArray(data.actions_run) ? data.actions_run : []
  const entry = list[index]
  if (!entry || typeof entry !== 'object') throw new Error(`No action run ${index}`)
  ;(entry as RawItem).undone_at = at
  return serializeFrontmatter(data, body)
}

/**
 * Normalize `relative` against a source-relative `base` folder. Returns `null` for
 * absolute paths or paths that would climb above the source root.
 */
export function joinRelativePath(base: string, relative: string): string | null {
  if (relative.startsWith('/') || relative.includes('\\') || relative.includes('\0')) return null
  const out = base.split('/').filter((s) => s.length > 0)
  for (const part of relative.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (out.length === 0) return null
      out.pop()
    } else {
      out.push(part)
    }
  }
  return out.join('/')
}

/**
 * Resolve a project's review folder from its effective `review_path`.
 *
 * `reviewPath` is relative to the project folder; `{folder}` is replaced with the
 * project folder's name. E.g. project `Tasks/Morrow` + `../../{folder}/review` →
 * `Morrow/review`. Returns `null` when unset or when it would escape the source root.
 */
export function resolveReviewPath(reviewPath: string | undefined, projectFolder: string): string | null {
  if (!reviewPath || reviewPath.trim().length === 0) return null
  const name = projectFolder.split('/').filter((s) => s.length > 0).pop() ?? ''
  const resolved = joinRelativePath(projectFolder, reviewPath.trim().replaceAll('{folder}', name))
  return resolved && resolved.length > 0 ? resolved : null
}

/** An item's file inside its request folder, as a source-relative path (`null` if it escapes the root). */
export function reviewAssetPath(requestFolder: string, file: string): string | null {
  return joinRelativePath(requestFolder, file)
}
