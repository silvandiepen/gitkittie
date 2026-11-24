import type { AppSlug } from './content'

/**
 * What a shared link shows. Used in the browser (`usePageMeta`), by the build step that
 * writes a static page per route (`build/static-pages.ts`) — link previews in Slack,
 * iMessage, LinkedIn or X do not run JavaScript, so the tags have to be in the HTML — and by
 * the share card renderer (`src/og/`). No browser or Vite APIs here, so all three can import it.
 */

export const siteName = 'GitKittie'

/** Size of every share card in `public/og/`. */
export const shareImageSize = { width: 1200, height: 630 }

/** A route that is not an article. Its title and description are `meta` in its content JSON. */
export interface StaticPage {
  path: string
  /** Content namespace (`src/i18n/locales/<locale>/<content>.json`) that holds `meta`. */
  content: string
  /** Key inside the namespace when `meta` is not at its top level. */
  key?: string
  app?: AppSlug
  /** Screenshot on the share card, from `public/`. */
  shot?: string
  shotAlt?: string
  changefreq: 'weekly' | 'monthly' | 'yearly'
  priority: number
}

export const staticPages: StaticPage[] = [
  { path: '/', content: 'home', shot: '/screenshots/tasks/mac-board-dark.webp', shotAlt: 'A GitKittie Tasks board on the Mac', changefreq: 'monthly', priority: 1 },
  { path: '/folder', content: 'folder', app: 'folder', shot: '/screenshots/folder/iphone-repos-dark.webp', shotAlt: 'GitKittie Folder listing repositories on iPhone', changefreq: 'monthly', priority: 0.9 },
  { path: '/tasks', content: 'tasks', app: 'tasks', shot: '/screenshots/tasks/mac-board-dark.webp', shotAlt: 'A GitKittie Tasks board on the Mac', changefreq: 'monthly', priority: 0.9 },
  { path: '/bud', content: 'bud', app: 'bud', shot: '/screenshots/bud/mac-history.webp', shotAlt: 'A branch history in GitKittie Bud on the Mac', changefreq: 'monthly', priority: 0.9 },
  { path: '/blog', content: 'blog', shot: '/screenshots/tasks/mac-task-dark.webp', shotAlt: 'A task open in its own window in GitKittie Tasks', changefreq: 'weekly', priority: 0.8 },
  { path: '/docs', content: 'docs', shot: '/screenshots/tasks/mac-list-dark.webp', shotAlt: 'The List view of a GitKittie Tasks board', changefreq: 'monthly', priority: 0.7 },
  { path: '/support', content: 'support', changefreq: 'monthly', priority: 0.6 },
  { path: '/privacy', content: 'legal', key: 'privacy', changefreq: 'yearly', priority: 0.3 },
  { path: '/terms', content: 'legal', key: 'terms', changefreq: 'yearly', priority: 0.3 },
]

/** `/` → `/og/home.png`, `/blog/a-post` → `/og/blog/a-post.png`. */
export function shareImagePath(path: string): string {
  return `/og/${path === '/' ? 'home' : path.replace(/^\/|\/$/g, '')}.png`
}

/**
 * The file a route is written to in `dist/`. `blog/a-post.html` rather than
 * `blog/a-post/index.html`: Cloudflare Pages serves it at `/blog/a-post`, with no
 * redirect to a trailing slash, so the address matches the canonical one.
 */
export function staticFileFor(path: string): string {
  return path === '/' ? 'index.html' : `${path.replace(/^\/|\/$/g, '')}.html`
}

export interface HeadMeta {
  title: string
  description: string
  /** Absolute canonical URL. */
  url: string
  /** Absolute share image URL. */
  image: string
  imageAlt: string
  type: 'website' | 'article'
  /** ISO date, for articles. */
  published?: string
  /** An article's own title, without the site name `title` ends with. */
  headline?: string
}

/** Every `<meta>` a shared link reads, as [attribute, key, content]. */
export function metaTags(meta: HeadMeta): Array<['name' | 'property', string, string]> {
  const tags: Array<['name' | 'property', string, string]> = [
    ['name', 'description', meta.description],
    ['property', 'og:site_name', siteName],
    ['property', 'og:type', meta.type],
    ['property', 'og:title', meta.title],
    ['property', 'og:description', meta.description],
    ['property', 'og:url', meta.url],
    ['property', 'og:image', meta.image],
    ['property', 'og:image:width', String(shareImageSize.width)],
    ['property', 'og:image:height', String(shareImageSize.height)],
    ['property', 'og:image:alt', meta.imageAlt],
    ['name', 'twitter:card', 'summary_large_image'],
    ['name', 'twitter:title', meta.title],
    ['name', 'twitter:description', meta.description],
    ['name', 'twitter:image', meta.image],
    ['name', 'twitter:image:alt', meta.imageAlt],
  ]
  if (meta.type === 'article' && meta.published) {
    tags.push(['property', 'article:published_time', meta.published])
  }
  return tags
}

/** schema.org data for an article: search engines read the headline, date and image from it. */
export function articleJsonLd(meta: HeadMeta, origin: string): Record<string, unknown> {
  return {
    '@context': 'https://schema.org',
    '@type': 'BlogPosting',
    headline: meta.headline ?? meta.title,
    description: meta.description,
    datePublished: meta.published,
    image: meta.image,
    url: meta.url,
    mainEntityOfPage: meta.url,
    author: { '@type': 'Organization', name: siteName, url: origin },
    publisher: { '@type': 'Organization', name: siteName, url: origin },
  }
}
