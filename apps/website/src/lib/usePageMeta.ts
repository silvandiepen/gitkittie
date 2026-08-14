import { toValue, watchEffect } from 'vue'
import type { MaybeRefOrGetter } from 'vue'
import { useRoute } from 'vue-router'
import { siteOrigin } from '@/links'

export interface PageMeta {
  /** Full document title. If omitted, the route meta title (via router) stands. */
  title: MaybeRefOrGetter<string>
  /** Meta + OG description. */
  description: MaybeRefOrGetter<string>
  /** Canonical path (defaults to the current route path). */
  path?: MaybeRefOrGetter<string | undefined>
  /** Absolute OG image URL (defaults to the site social image). */
  image?: MaybeRefOrGetter<string | undefined>
}

function upsertMeta(selector: string, attr: 'name' | 'property', key: string, content: string) {
  let el = document.head.querySelector<HTMLMetaElement>(selector)
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

/**
 * Lightweight per-page head management (title, description, canonical, OG/Twitter)
 * without pulling in a head-management dependency. Call once from a page's setup.
 *
 * Fields accept refs and getters as well as plain strings: a route like
 * `/blog/:slug` keeps the same component mounted across navigations, so its
 * title has to be reactive or the second article inherits the first one's head.
 */
export function usePageMeta(meta: PageMeta) {
  const route = useRoute()

  watchEffect(() => {
    const title = toValue(meta.title)
    const description = toValue(meta.description)
    const path = toValue(meta.path) ?? route.path
    const url = `${siteOrigin}${path === '/' ? '' : path}`
    const image = toValue(meta.image) ?? `${siteOrigin}/og-image.png`

    document.title = title

    upsertMeta('meta[name="description"]', 'name', 'description', description)
    upsertCanonical(url)

    upsertMeta('meta[property="og:type"]', 'property', 'og:type', 'website')
    upsertMeta('meta[property="og:title"]', 'property', 'og:title', title)
    upsertMeta('meta[property="og:description"]', 'property', 'og:description', description)
    upsertMeta('meta[property="og:url"]', 'property', 'og:url', url)
    upsertMeta('meta[property="og:image"]', 'property', 'og:image', image)

    upsertMeta('meta[name="twitter:card"]', 'name', 'twitter:card', 'summary_large_image')
    upsertMeta('meta[name="twitter:title"]', 'name', 'twitter:title', title)
    upsertMeta('meta[name="twitter:description"]', 'name', 'twitter:description', description)
    upsertMeta('meta[name="twitter:image"]', 'name', 'twitter:image', image)
  })
}
