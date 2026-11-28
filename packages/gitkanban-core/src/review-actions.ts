import { bool, record, str } from './review-values.js'

/**
 * Actions on decision (ReviewSpec § 2): what happens to cards when a request, an item or a
 * check is accepted, gets changes requested, or is rejected.
 *
 * ```yaml
 * on_accept:  { to: testing }                      # move defaults to the request's card
 * on_changes: { to: in-progress, comment: true, assign: claude }
 * on_reject:  [{ to: todo }, { move: PROJ-9, to: todo }]
 * ```
 *
 * The app records what it did in the request's `actions_run` (append-only; only
 * `undone_at` is set later), so the agent never moves a card a review already moved.
 */

export type ReviewOutcome = 'accept' | 'changes' | 'reject'
export const REVIEW_OUTCOMES: readonly ReviewOutcome[] = ['accept', 'changes', 'reject']

/** The frontmatter key of each outcome's actions. */
export const ACTION_KEYS: Record<ReviewOutcome, string> = { accept: 'on_accept', changes: 'on_changes', reject: 'on_reject' }

export interface ReviewAction {
  /** Card id on the same board; absent = the request's `card` (request level only). */
  move?: string
  /** Lane: id, status or name. */
  to: string
  /** Copy the deciding comments into the card's activity log. */
  comment: boolean
  /** Set the card's `assignee` to this board user. */
  assign?: string
}

export interface ReviewActions {
  accept: ReviewAction[]
  changes: ReviewAction[]
  reject: ReviewAction[]
}

export type ActionRunResult = 'moved' | 'already' | 'skipped' | 'undone'
export const ACTION_RUN_RESULTS: readonly ActionRunResult[] = ['moved', 'already', 'skipped', 'undone']

/** One action the app ran (or skipped), as `actions_run` records it. */
export interface ActionRun {
  on: ReviewOutcome
  /** `undefined` for the request; an item or check id otherwise. */
  entry?: string
  card: string
  /** The lane id the card was in. */
  from?: string
  to: string
  result: ActionRunResult
  /** Why it was skipped. */
  reason?: string
  by: string
  at: string
  undoneAt?: string
  /** Values of the card's fields the action changed, as they were before (for Undo). */
  before: Record<string, string | null>
}

function parseAction(value: unknown): ReviewAction | null {
  const r = record(value)
  if (!r) return null
  const to = str(r.to)
  if (!to) return null
  const action: ReviewAction = { to, comment: bool(r.comment) }
  const move = str(r.move)
  if (move) action.move = move
  const assign = str(r.assign)
  if (assign) action.assign = assign
  return action
}

/** One action or a list of them; entries without `to` are left out. */
export function parseActionList(value: unknown): ReviewAction[] {
  const list = Array.isArray(value) ? value : value === undefined || value === null ? [] : [value]
  return list.map(parseAction).filter((action): action is ReviewAction => action !== null)
}

export function parseActions(raw: Record<string, unknown>): ReviewActions {
  return {
    accept: parseActionList(raw.on_accept),
    changes: parseActionList(raw.on_changes),
    reject: parseActionList(raw.on_reject),
  }
}

export function hasActions(actions: ReviewActions): boolean {
  return actions.accept.length + actions.changes.length + actions.reject.length > 0
}

export function parseActionsRun(value: unknown): ActionRun[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const r = record(entry)
    if (!r) return []
    const on = str(r.on)
    const card = str(r.card)
    const to = str(r.to)
    const result = str(r.result)
    if (!on || !(REVIEW_OUTCOMES as readonly string[]).includes(on) || !card || !to) return []
    const before: Record<string, string | null> = {}
    const rawBefore = record(r.before)
    if (rawBefore) for (const [key, val] of Object.entries(rawBefore)) before[key] = str(val) ?? null
    const run: ActionRun = {
      on: on as ReviewOutcome,
      card,
      to,
      result: result && (ACTION_RUN_RESULTS as readonly string[]).includes(result) ? (result as ActionRunResult) : 'moved',
      by: str(r.by) ?? 'unknown',
      at: str(r.at) ?? '',
      before,
    }
    const entryID = str(r.entry)
    if (entryID) run.entry = entryID
    const from = str(r.from)
    if (from) run.from = from
    const reason = str(r.reason)
    if (reason) run.reason = reason
    const undone = str(r.undone_at)
    if (undone) run.undoneAt = undone
    return [run]
  })
}

/** An `actions_run` entry as written to the file. */
export function actionRunRecord(run: ActionRun): Record<string, unknown> {
  const out: Record<string, unknown> = {
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
  }
  if (Object.keys(run.before).length > 0) out.before = run.before
  return out
}
