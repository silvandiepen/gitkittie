/** Reading loosely typed frontmatter values, shared by the review modules. */

export interface ReviewComment {
  by: string
  at: string
  text: string
  /** A marked-up copy of the entry the comment is about, relative to the request folder. */
  image?: string
}

/** A scalar as trimmed text; `undefined` for absent, null, empty or non-scalar values. */
export function str(value: unknown): string | undefined {
  if (value === null || value === undefined) return undefined
  if (value instanceof Date) return value.toISOString()
  if (typeof value === 'object') return undefined
  const s = String(value).trim()
  return s.length > 0 ? s : undefined
}

/** A positive number, from a number or numeric text. */
export function num(value: unknown): number | undefined {
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) && n > 0 ? n : undefined
}

export function bool(value: unknown): boolean {
  return value === true || ['true', 'yes', 'on'].includes(str(value)?.toLowerCase() ?? '')
}

/** A list of ids: `[a, b]`, or a single `a`. */
export function ids(value: unknown): string[] {
  if (Array.isArray(value)) return value.map(str).filter((id): id is string => id !== undefined)
  const one = str(value)
  return one ? [one] : []
}

export function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined
}

export function parseComments(value: unknown): ReviewComment[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry) => {
    const r = record(entry)
    const text = r ? str(r.text) : undefined
    if (!r || !text) return []
    const comment: ReviewComment = { by: str(r.by) ?? 'unknown', at: str(r.at) ?? '', text }
    const image = str(r.image)
    if (image) comment.image = image
    return [comment]
  })
}
