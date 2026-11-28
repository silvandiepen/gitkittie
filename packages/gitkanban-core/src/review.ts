import { parseFrontmatter, serializeFrontmatter } from './frontmatter.js'

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

export interface ReviewComment {
  by: string
  at: string
  text: string
}

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
  items: ReviewItem[]
  questions: ReviewQuestion[]
  /** Free-form notes below the frontmatter. */
  body: string
}

export interface ReviewSummary {
  /** Items and questions. */
  total: number
  /** Items without a decision and questions without an answer. */
  pending: number
  approved: number
  rejected: number
  changesRequested: number
  /** Decided or answered by the reviewer but not yet acted on by the agent (`handled_at` unset). */
  awaitingAgent: number
  questions: number
  answered: number
}

function str(value: unknown): string | undefined {
  if (value === null || value === undefined) return undefined
  if (value instanceof Date) return value.toISOString()
  const s = String(value).trim()
  return s.length > 0 ? s : undefined
}

function num(value: unknown): number | undefined {
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) && n > 0 ? n : undefined
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

function parseComments(value: unknown): ReviewComment[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    if (!entry || typeof entry !== 'object') return []
    const record = entry as Record<string, unknown>
    const text = str(record.text)
    if (!text) return []
    return [{ by: str(record.by) ?? 'unknown', at: str(record.at) ?? '', text }]
  })
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
  const other = r.other === true || ['true', 'yes', 'on'].includes(str(r.other)?.toLowerCase() ?? '')
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
  const id = str(data.id) ?? fallbackId
  return {
    id,
    project: str(data.project),
    card: str(data.card),
    title: str(data.title) ?? id,
    question: str(data.question),
    requestedBy: str(data.requested_by),
    requestedAt: str(data.requested_at),
    notify: parseNotify(data.notify),
    items,
    questions,
    body,
  }
}

/**
 * What still waits for the reviewer: ids of items without a decision and of questions
 * without an answer (`item:<id>` / `question:<id>`, since the two may share an id in a
 * hand-written file). Empty when the request needs no answer.
 */
export function waitingEntries(review: ReviewRequest): string[] {
  return [
    ...review.items.filter((item) => item.status === 'pending').map((item) => `item:${item.id}`),
    ...review.questions.filter((question) => !isQuestionAnswered(question)).map((question) => `question:${question.id}`),
  ]
}

export function summarizeReview(review: ReviewRequest): ReviewSummary {
  const summary: ReviewSummary = {
    total: review.items.length,
    pending: 0,
    approved: 0,
    rejected: 0,
    changesRequested: 0,
    awaitingAgent: 0,
    questions: review.questions.length,
    answered: 0,
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
  for (const item of review.items) {
    if (item.status === 'pending') summary.pending += 1
    else {
      if (item.status === 'approved') summary.approved += 1
      if (item.status === 'rejected') summary.rejected += 1
      if (item.status === 'changes-requested') summary.changesRequested += 1
      if (!item.handledAt) summary.awaitingAgent += 1
    }
  }
  return summary
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
