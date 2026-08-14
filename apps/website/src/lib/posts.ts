import type { AppSlug } from './content'

/**
 * Blog post registry.
 *
 * Same split as the rest of the site: prose lives in Markdown, outside
 * components, so it can be translated — `src/i18n/posts/<locale>/<slug>.md`.
 * Unlike the legal pages, an article carries its own metadata (title, date,
 * summary), so each file opens with a small frontmatter block rather than
 * keeping that in a parallel JSON file where it would drift from the prose.
 *
 * Adding an article = dropping one `.md` file in the folder. Nothing else.
 */

/** Frontmatter as authored, plus the derived fields the pages render. */
export interface Post {
  slug: string
  title: string
  /** One-sentence summary — the card excerpt and the page meta description. */
  description: string
  /** ISO date (`YYYY-MM-DD`); drives ordering and the displayed date. */
  date: string
  /** Optional product the piece is about — themes the page via `[data-app]`. */
  app?: AppSlug
  /** Slugs of articles to surface at the end of this one. */
  related: string[]
  /** Markdown body, frontmatter stripped. */
  body: string
  /** Minutes, rounded up, at 200 wpm. */
  readingMinutes: number
}

const DEFAULT_LOCALE = 'en'

const postModules = import.meta.glob('../i18n/posts/*/*.md', {
  eager: true,
  query: '?raw',
  import: 'default',
}) as Record<string, string>

/**
 * Frontmatter is a deliberately small subset of YAML: `key: value` lines
 * between two `---` fences, with `related` as a comma-separated list. Enough
 * for an article header, and no parser dependency to carry for it.
 */
function parseFrontmatter(raw: string): { fields: Record<string, string>; body: string } {
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

function readingMinutes(body: string): number {
  const words = body.trim().split(/\s+/).filter(Boolean).length
  return Math.max(1, Math.ceil(words / 200))
}

function toPost(path: string, raw: string): Post {
  const slug = path.replace(/^.*\/(.+)\.md$/, '$1')
  const { fields, body } = parseFrontmatter(raw)

  return {
    slug,
    title: fields.title ?? slug,
    description: fields.description ?? '',
    date: fields.date ?? '',
    app: (fields.app as AppSlug) || undefined,
    related: fields.related ? fields.related.split(',').map((s) => s.trim()).filter(Boolean) : [],
    body,
    readingMinutes: readingMinutes(body),
  }
}

/** Every article for a locale, newest first. */
export function usePosts(locale: string = DEFAULT_LOCALE): Post[] {
  return Object.entries(postModules)
    .filter(([path]) => path.includes(`/posts/${locale}/`))
    .map(([path, raw]) => toPost(path, raw))
    .sort((a, b) => b.date.localeCompare(a.date))
}

/** One article by slug, or `undefined` when the slug does not exist. */
export function usePost(slug: string, locale: string = DEFAULT_LOCALE): Post | undefined {
  return usePosts(locale).find((post) => post.slug === slug)
}

/** The articles a given post points at, in the order it lists them. */
export function useRelatedPosts(post: Post, locale: string = DEFAULT_LOCALE): Post[] {
  const all = usePosts(locale)
  return post.related
    .map((slug) => all.find((candidate) => candidate.slug === slug))
    .filter((candidate): candidate is Post => Boolean(candidate))
}

/** `2026-08-14` → `14 August 2026`, for display. */
export function formatPostDate(date: string): string {
  const parsed = new Date(`${date}T00:00:00Z`)
  if (Number.isNaN(parsed.getTime())) return date
  return parsed.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' })
}
