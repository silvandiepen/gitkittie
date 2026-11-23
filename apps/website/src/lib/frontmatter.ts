/**
 * Article frontmatter, shared by the site (`posts.ts`) and the build step that writes a
 * static page per article (`build/static-pages.ts`). No browser or Vite APIs here, so both
 * can import it.
 *
 * Frontmatter is a deliberately small subset of YAML: `key: value` lines between two `---`
 * fences, with lists comma-separated. Enough for an article header, and no parser
 * dependency to carry for it.
 */

export interface Frontmatter {
  fields: Record<string, string>
  body: string
}

export function parseFrontmatter(raw: string): Frontmatter {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(raw)
  if (!match) return { fields: {}, body: raw }

  const fields: Record<string, string> = {}
  for (const line of match[1].split(/\r?\n/)) {
    const separator = line.indexOf(':')
    if (separator === -1) continue
    const key = line.slice(0, separator).trim()
    const value = line.slice(separator + 1).trim().replace(/^["']|["']$/g, '')
    if (key) fields[key] = value
  }

  return { fields, body: raw.slice(match[0].length) }
}

/** Fields every article must have: without them it would be shared with no title, text or picture. */
export const requiredPostFields = ['title', 'description', 'date', 'shot', 'shotAlt'] as const

/** The required fields an article is missing, by name. */
export function missingPostFields(fields: Record<string, string>): string[] {
  return requiredPostFields.filter((key) => !fields[key])
}

/** Minutes, rounded up, at 200 words a minute. */
export function readingMinutes(body: string): number {
  const words = body.trim().split(/\s+/).filter(Boolean).length
  return Math.max(1, Math.ceil(words / 200))
}
