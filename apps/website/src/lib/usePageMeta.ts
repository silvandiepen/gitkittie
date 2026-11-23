import { toValue, watchEffect } from 'vue'
import type { MaybeRefOrGetter } from 'vue'
import { useRoute } from 'vue-router'
import { siteOrigin } from '@/links'
import { articleJsonLd, metaTags, shareImagePath, staticPages, type HeadMeta } from './seo'

export interface PageMeta {
  /** Full document title. If omitted, the route meta title (via router) stands. */
  title: MaybeRefOrGetter<string>
  /** Meta + OG description. */
  description: MaybeRefOrGetter<string>
  /** Canonical path (defaults to the current route path). */
  path?: MaybeRefOrGetter<string | undefined>
  /** What the share card shows (defaults to the page's own screenshot description, or its title). */
  imageAlt?: MaybeRefOrGetter<string | undefined>
  /** `article` for a blog post; pages are `website`. */
  type?: MaybeRefOrGetter<HeadMeta['type'] | undefined>
  /** ISO date an article was published. */
  published?: MaybeRefOrGetter<string | undefined>
  /** An article's own title, without the site name. */
  headline?: MaybeRefOrGetter<string | undefined>
}

function upsertMeta(attr: 'name' | 'property', key: string, content: string) {
  let el = document.head.querySelector<HTMLMetaElement>(`meta[${attr}="${key}"]`)
  if (!el) {
    el = document.createElement('meta')
    el.setAttribute(attr, key)
    document.head.appendChild(el)
  }
  el.setAttribute('content', content)
}

function upsertCanonical(href: string) {
  let el = document.head.querySelector<HTMLLinkElement>('link[rel="canonical"]')
  if (!el) {
    el = document.createElement('link')
    el.setAttribute('rel', 'canonical')
    document.head.appendChild(el)
  }
  el.setAttribute('href', href)
}

/** The article data the static page carried, or none on a page that is not an article. */
function setJsonLd(data: Record<string, unknown> | undefined) {
  document.head.querySelector('script[type="application/ld+json"]')?.remove()
  if (!data) return
  const el = document.createElement('script')
  el.type = 'application/ld+json'
  el.textContent = JSON.stringify(data)
  document.head.appendChild(el)
}

/**
 * Per-page head (title, description, canonical, Open Graph, Twitter, article data) without
 * a head-management dependency. Call once from a page's setup.
 *
 * The build writes the same tags into a static HTML file per route (see
 * `build/static-pages.ts`), because link previews do not run JavaScript. This keeps them
 * right while you move around the site; both come from `seo.ts`, so they agree.
 *
 * Fields accept refs and getters as well as plain strings: a route like `/blog/:slug` keeps
 * the same component mounted across navigations, so its title has to be reactive or the
 * second article inherits the first one's head.
 */
export function usePageMeta(meta: PageMeta) {
  const route = useRoute()

  watchEffect(() => {
    const path = toValue(meta.path) ?? route.path
    const head: HeadMeta = {
      title: toValue(meta.title),
      description: toValue(meta.description),
      url: `${siteOrigin}${path === '/' ? '' : path}`,
      image: `${siteOrigin}${shareImagePath(path)}`,
      imageAlt: toValue(meta.imageAlt) ?? staticPages.find((page) => page.path === path)?.shotAlt ?? toValue(meta.title),
      type: toValue(meta.type) ?? 'website',
      published: toValue(meta.published),
      headline: toValue(meta.headline),
    }

    document.title = head.title
    upsertCanonical(head.url)
    for (const [attr, key, content] of metaTags(head)) upsertMeta(attr, key, content)
    if (head.type !== 'article') document.head.querySelector('meta[property="article:published_time"]')?.remove()
    setJsonLd(head.type === 'article' ? articleJsonLd(head, siteOrigin) : undefined)
  })
}
