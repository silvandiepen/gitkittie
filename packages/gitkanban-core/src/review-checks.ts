import { parseActions, type ReviewActions } from './review-actions.js'
import { ids, num, parseComments, record, str, type ReviewComment } from './review-values.js'

/**
 * Browser checks (ReviewSpec § 3): "open this page and check these things, at these sizes".
 * A check is a top-level `checks:` entry next to `items:` and `questions:`. Each line of its
 * checklist is answered pass, fail or with a note, per size (and per appearance when the
 * check lists light and dark); the check as a whole is decided like a file.
 */

export type CheckUserAgent = 'mobile' | 'desktop' | 'default'
export type CheckAppearance = 'light' | 'dark'
export type CheckAnswerResult = 'pass' | 'fail' | 'note'

export const CHECK_APPEARANCES: readonly CheckAppearance[] = ['light', 'dark']
export const CHECK_ANSWER_RESULTS: readonly CheckAnswerResult[] = ['pass', 'fail', 'note']

/** The size a check without `sizes` has: whatever window or screen it is opened in. */
export const DEFAULT_CHECK_SIZE = 'default'
/** Results taken at a size the reviewer chose freely on the Mac. */
export const CUSTOM_CHECK_SIZE = 'custom'

export interface CheckSize {
  id: string
  label: string
  /** CSS pixels; absent for `default` and for an id this version does not know. */
  width?: number
  height?: number
  ua: CheckUserAgent
}

/** Generic names, so they don't age with device models. */
export const CHECK_SIZE_PRESETS: readonly CheckSize[] = [
  { id: 'phone-small', label: 'Small phone', width: 375, height: 667, ua: 'mobile' },
  { id: 'phone', label: 'Phone', width: 390, height: 844, ua: 'mobile' },
  { id: 'phone-large', label: 'Large phone', width: 440, height: 956, ua: 'mobile' },
  { id: 'tablet', label: 'Tablet', width: 820, height: 1180, ua: 'mobile' },
  { id: 'tablet-landscape', label: 'Tablet landscape', width: 1180, height: 820, ua: 'mobile' },
  { id: 'laptop', label: 'Laptop', width: 1280, height: 800, ua: 'desktop' },
  { id: 'desktop', label: 'Desktop', width: 1440, height: 900, ua: 'desktop' },
  { id: 'wide', label: 'Wide', width: 1920, height: 1080, ua: 'desktop' },
]

const WXH = /^(\d{2,5})x(\d{2,5})$/

/** A size as written: a preset id, `WIDTHxHEIGHT`, or a mapping `{ id, label, width, height, ua }`. */
export function parseCheckSize(value: unknown): CheckSize | null {
  const r = record(value)
  if (r) {
    const width = num(r.width)
    const height = num(r.height)
    const id = str(r.id) ?? (width && height ? `${width}x${height}` : undefined)
    if (!id) return null
    const preset = CHECK_SIZE_PRESETS.find((p) => p.id === id)
    const ua = str(r.ua)
    const size: CheckSize = {
      id,
      label: str(r.label) ?? preset?.label ?? id,
      ua: ua === 'mobile' || ua === 'desktop' || ua === 'default' ? ua : preset?.ua ?? 'default',
    }
    const w = width ?? preset?.width
    const h = height ?? preset?.height
    if (w && h) {
      size.width = w
      size.height = h
    }
    return size
  }
  const id = str(value)
  if (!id) return null
  const preset = CHECK_SIZE_PRESETS.find((p) => p.id === id.toLowerCase())
  if (preset) return { ...preset }
  const match = WXH.exec(id)
  if (match) return { id, label: id, width: Number(match[1]), height: Number(match[2]), ua: 'default' }
  return { id, label: id, ua: 'default' }
}

export interface CheckLine {
  id: string
  text: string
}

export interface CheckAnswer {
  result: CheckAnswerResult
  note?: string
  at?: string
}

/** What was found at one size (and appearance). */
export interface CheckResult {
  viewport?: string
  by?: string
  at?: string
  /** Relative to the request folder, `results/<check>-<key>.png`. */
  screenshot?: string
  /** By checklist line id. */
  answers: Record<string, CheckAnswer>
}

export type ReviewCheckStatus = 'pending' | 'approved' | 'rejected' | 'changes-requested'

export interface ReviewCheck {
  id: string
  url: string
  title?: string
  note?: string
  sizes: CheckSize[]
  appearance: CheckAppearance[]
  checklist: CheckLine[]
  revises?: string
  actions: ReviewActions
  /** By size key: `<size id>` or `<size id>.<appearance>`. */
  results: Record<string, CheckResult>
  status: ReviewCheckStatus
  decidedBy?: string
  decidedAt?: string
  comments: ReviewComment[]
  handledAt?: string
}

/** One failed (or noted) line, as `list_reviews` reports it. */
export interface CheckFailure {
  size: string
  item: string
  text: string
  result: CheckAnswerResult
  note?: string
  screenshot?: string
}

function slugID(text: string, index: number): string {
  const slug = text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/g, '')
  return slug.length > 0 ? slug : `line-${index + 1}`
}

/** A checklist line id made from its text: lower case words joined by `-`. */
export function checklistID(text: string, index = 0): string {
  return slugID(text, index)
}

function parseChecklist(value: unknown): CheckLine[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry, index) => {
    const r = record(entry)
    if (r) {
      const text = str(r.text)
      if (!text) return []
      return [{ id: str(r.id) ?? slugID(text, index), text }]
    }
    const text = str(entry)
    return text ? [{ id: slugID(text, index), text }] : []
  })
}

function parseResults(value: unknown): Record<string, CheckResult> {
  const r = record(value)
  const out: Record<string, CheckResult> = {}
  if (!r) return out
  for (const [key, raw] of Object.entries(r)) {
    const entry = record(raw)
    if (!entry) continue
    const answers: Record<string, CheckAnswer> = {}
    const rawAnswers = record(entry.answers)
    if (rawAnswers) {
      for (const [line, rawAnswer] of Object.entries(rawAnswers)) {
        const a = record(rawAnswer)
        const result = str(a ? a.result : rawAnswer)
        if (!result || !(CHECK_ANSWER_RESULTS as readonly string[]).includes(result)) continue
        const answer: CheckAnswer = { result: result as CheckAnswerResult }
        const note = a ? str(a.note) : undefined
        if (note) answer.note = note
        const at = a ? str(a.at) : undefined
        if (at) answer.at = at
        answers[line] = answer
      }
    }
    const result: CheckResult = { answers }
    for (const [field, keyName] of [['viewport', 'viewport'], ['by', 'by'], ['at', 'at'], ['screenshot', 'screenshot']] as const) {
      const v = str(entry[keyName])
      if (v) result[field] = v
    }
    out[key] = result
  }
  return out
}

const STATUSES: readonly ReviewCheckStatus[] = ['pending', 'approved', 'rejected', 'changes-requested']

export function parseCheck(value: unknown, index: number): ReviewCheck | null {
  const r = record(value)
  if (!r) return null
  const url = str(r.url)
  if (!url) return null
  const sizes = (Array.isArray(r.sizes) ? r.sizes : r.sizes === undefined || r.sizes === null ? [] : [r.sizes])
    .map(parseCheckSize)
    .filter((size): size is CheckSize => size !== null)
  const appearance = ids(r.appearance)
    .map((a) => a.toLowerCase())
    .filter((a): a is CheckAppearance => (CHECK_APPEARANCES as readonly string[]).includes(a))
  const status = str(r.status)
  const check: ReviewCheck = {
    id: str(r.id) ?? `check-${index + 1}`,
    url,
    sizes,
    appearance: [...new Set(appearance)],
    checklist: parseChecklist(r.checklist),
    actions: parseActions(r),
    results: parseResults(r.results),
    status: status && (STATUSES as readonly string[]).includes(status) ? (status as ReviewCheckStatus) : 'pending',
    comments: parseComments(r.comments),
  }
  for (const [field, keyName] of [
    ['title', 'title'],
    ['note', 'note'],
    ['revises', 'revises'],
    ['decidedBy', 'decided_by'],
    ['decidedAt', 'decided_at'],
    ['handledAt', 'handled_at'],
  ] as const) {
    const v = str(r[keyName])
    if (v) check[field] = v
  }
  return check
}

/** The sizes a check is answered at: its own, or the one `default` size. */
export function checkSizes(check: ReviewCheck): CheckSize[] {
  return check.sizes.length > 0 ? check.sizes : [{ id: DEFAULT_CHECK_SIZE, label: 'Default', ua: 'default' }]
}

/** Every key a check's results are stored under: each size, or each size × appearance. */
export function checkResultKeys(check: ReviewCheck): string[] {
  const sizes = checkSizes(check).map((s) => s.id)
  if (check.appearance.length === 0) return sizes
  return sizes.flatMap((size) => check.appearance.map((a) => `${size}.${a}`))
}

/** The result key for a size and an optional appearance. */
export function checkResultKey(size: string, appearance?: CheckAppearance): string {
  return appearance ? `${size}.${appearance}` : size
}

/** How many lines are answered at a key, of how many. */
export function checkProgress(check: ReviewCheck, key: string): { answered: number; total: number } {
  const answers = check.results[key]?.answers ?? {}
  return { answered: check.checklist.filter((line) => answers[line.id] !== undefined).length, total: check.checklist.length }
}

/** Every line answered `fail` or `note`, in key then checklist order. */
export function checkFailures(check: ReviewCheck): CheckFailure[] {
  const keys = [...checkResultKeys(check), ...Object.keys(check.results).filter((k) => !checkResultKeys(check).includes(k))]
  return keys.flatMap((key) => {
    const result = check.results[key]
    if (!result) return []
    return check.checklist.flatMap((line) => {
      const answer = result.answers[line.id]
      if (!answer || answer.result === 'pass') return []
      const failure: CheckFailure = { size: key, item: line.id, text: line.text, result: answer.result }
      if (answer.note) failure.note = answer.note
      if (result.screenshot) failure.screenshot = result.screenshot
      return [failure]
    })
  })
}

/** Where a screenshot of `check` at `key` goes, relative to the request folder. */
export function checkScreenshotPath(checkID: string, key: string): string {
  return `results/${checkID}-${key}.png`
}

/** Addresses only the machine that serves them can open (`localhost`, `127.0.0.1`, `*.local`). */
export function isLocalOnlyURL(url: string): boolean {
  let host: string
  try {
    host = new URL(url).hostname.toLowerCase()
  } catch {
    return false
  }
  return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]' || host.endsWith('.local')
}
