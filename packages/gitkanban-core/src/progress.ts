import type { Lane } from './types.js'

/**
 * Progress view: the board folded into three stages, so you can follow agent work at a
 * glance instead of reading lane by lane.
 *
 * - `pipeline`   — lanes before the in-progress lane (To do, Backlog)
 * - `working`    — the in-progress lane
 * - `checkedOff` — lanes after it (In Review, Testing, Done) and any terminal lane
 *
 * A checked-off card is *unread* until the reviewer marks it read (`read_at`), and becomes
 * unread again when it's updated after that (`updated_at` > `read_at`).
 */

export type ProgressStage = 'working' | 'pipeline' | 'checkedOff'

export const PROGRESS_STAGES: readonly ProgressStage[] = ['working', 'pipeline', 'checkedOff']

function isProgressLane(lane: Lane): boolean {
  const text = `${lane.id} ${lane.status} ${lane.name}`.toLowerCase()
  return text.includes('progress') || /\bdoing\b/.test(text)
}

/** The stage a lane belongs to, given the board's lanes in order. */
export function stageForLane(lane: Lane, lanes: readonly Lane[]): ProgressStage {
  if (lane.terminal) return 'checkedOff'
  const index = lanes.findIndex((l) => l.id === lane.id)
  const progress = lanes.findIndex(isProgressLane)
  if (progress >= 0 && index >= 0) {
    if (index < progress) return 'pipeline'
    if (index === progress) return 'working'
    return 'checkedOff'
  }
  // No recognisable in-progress lane: first lane is the queue, the last one is done.
  if (index <= 0) return 'pipeline'
  if (index === lanes.length - 1) return 'checkedOff'
  return 'working'
}

function time(value: unknown): number | undefined {
  if (value instanceof Date) return value.getTime()
  if (typeof value !== 'string' || value.trim().length === 0) return undefined
  const ms = Date.parse(value)
  return Number.isNaN(ms) ? undefined : ms
}

/** Whether a checked-off card still needs reading: never read, or updated since. */
export function isUnread(frontmatter: Record<string, unknown>): boolean {
  const read = time(frontmatter.read_at)
  if (read === undefined) return true
  const updated = time(frontmatter.updated_at)
  return updated !== undefined && updated > read
}

/**
 * The newest entry of a card's `## Activity log`, without its bullet, e.g.
 * "2026-11-08T20:15:00Z — `claude` claimed the task". Entries are appended, so it's the last.
 */
export function latestActivity(body: string): string | undefined {
  const lines = body.split('\n')
  const start = lines.findIndex((line) => /^#{2,3}\s+activity log\s*$/i.test(line.trim()))
  if (start < 0) return undefined
  let latest: string | undefined
  for (const line of lines.slice(start + 1)) {
    if (/^#{1,3}\s/.test(line)) break
    const match = /^\s*[-*]\s+(.*\S)\s*$/.exec(line)
    if (match) latest = match[1]
  }
  return latest
}
