import type { AppSlug } from './content'
import { missingPostFields, parseFrontmatter, readingMinutes } from './frontmatter'

/**
 * Blog post registry.
 *
 * Same split as the rest of the site: prose lives in Markdown, outside
 * components, so it can be translated — `src/i18n/posts/<locale>/<slug>.md`.
 * Unlike the legal pages, an article carries its own metadata (title, date,
 * summary), so each file opens with a small frontmatter block rather than
 * keeping that in a parallel JSON file where it would drift from the prose.
 *
 * Adding an article = dropping one `.md` file in the folder, then `npm run og` for its
 * share card. The build fails on an article without its title, description, date or
 * share screenshot, or without its card.
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
  /**
   * Screenshot on the article's share card, from `public/` (`/screenshots/…`). The card
   * itself is `public/og/blog/<slug>.png`, made by `npm run og`.
   */
  shot: string
  /** What the screenshot shows, for the share card's `og:image:alt`. */
  shotAlt: string
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

function toPost(path: string, raw: string): Post {
  const slug = path.replace(/^.*\/(.+)\.md$/, '$1')
  const { fields, body } = parseFrontmatter(raw)
  const missing = missingPostFields(fields)
  if (missing.length) throw new Error(`Article ${slug} is missing ${missing.join(', ')} in its frontmatter`)

  return {
    slug,
    title: fields.title ?? slug,
    description: fields.description ?? '',
    date: fields.date ?? '',
    app: (fields.app as AppSlug) || undefined,
    shot: fields.shot,
    shotAlt: fields.shotAlt,
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
