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
 *   `handled_at`, `shipped_to` on items
 * - reviewer: `status`, `decided_by`, `decided_at` on items
 * - both: `comments` (append-only)
 *
 * Every write here re-parses the current text and changes only the reviewer's
 * fields, so unknown keys and the agent's fields round-trip untouched.
 */

export const REVIEW_FILE = 'review.md'

export type ReviewStatus = 'pending' | 'approved' | 'rejected' | 'changes-requested'
export type ReviewKind = 'image' | 'model' | 'audio' | 'animation' | 'video' | 'other'

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

export interface ReviewRequest {
  id: string
  project?: string
  card?: string
  title: string
  question?: string
  requestedBy?: string
  requestedAt?: string
  items: ReviewItem[]
  /** Free-form notes below the frontmatter. */
  body: string
}

export interface ReviewSummary {
  total: number
  pending: number
  approved: number
  rejected: number
  changesRequested: number
  /** Decided by the reviewer but not yet acted on by the agent (`handled_at` unset). */
  awaitingAgent: number
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

/**
 * Parse a `review.md`. `fallbackId` (usually the request folder name) is used when
 * the frontmatter has no `id`.
 */
export function parseReview(text: string, fallbackId = 'review'): ReviewRequest {
  const { data, body } = parseFrontmatter(text)
  const items = Array.isArray(data.items)
    ? data.items.map(parseItem).filter((item): item is ReviewItem => item !== null)
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
    items,
    body,
  }
}

export function summarizeReview(review: ReviewRequest): ReviewSummary {
  const summary: ReviewSummary = {
    total: review.items.length,
    pending: 0,
    approved: 0,
    rejected: 0,
    changesRequested: 0,
    awaitingAgent: 0,
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
