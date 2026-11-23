import { useContent } from '@/i18n'
import { usePosts } from '@/lib/posts'
import { shareImagePath, staticPages } from '@/lib/seo'
import type { AppSlug, ShotDevice } from '@/lib/content'

/** What one share card shows. */
export interface ShareCardContent {
  /** Small label above the title: the product, or "Writing" for an article. */
  eyebrow: string
  title: string
  description: string
  app?: AppSlug
  shot?: string
  device?: ShotDevice
}

const appNames: Record<AppSlug, string> = {
  folder: 'GitKittie Folder',
  tasks: 'GitKittie Tasks',
  bud: 'GitKittie Bud',
}

/** The device a screenshot was taken on, from its file name. */
function deviceOf(shot: string): ShotDevice {
  if (shot.includes('/iphone')) return 'phone'
  if (shot.includes('/ipad')) return 'tablet'
  return 'mac'
}

/** Every card to make, and the file it is saved to under `public/`. */
export function shareCards(): Array<{ path: string; file: string }> {
  return [...staticPages.map((page) => page.path), ...usePosts().map((post) => `/blog/${post.slug}`)].map((path) => ({
    path,
    file: shareImagePath(path),
  }))
}

export function shareCard(path: string): ShareCardContent {
  const slug = /^\/blog\/(.+)$/.exec(path)?.[1]
  if (slug) {
    const post = usePosts().find((candidate) => candidate.slug === slug)
    if (!post) throw new Error(`No article ${slug}`)
    return {
      eyebrow: post.app ? `Writing · ${appNames[post.app]}` : 'Writing · GitKittie',
      title: post.title,
      description: post.description,
      app: post.app,
      shot: post.shot,
      device: deviceOf(post.shot),
    }
  }

  const page = staticPages.find((candidate) => candidate.path === path)
  if (!page) throw new Error(`No page ${path}`)
  const content = useContent<Record<string, { meta: { title: string; description: string } }> & { meta?: { title: string; description: string } }>(page.content)
  const meta = page.key ? content[page.key].meta : content.meta!
  // "GitKittie Tasks — Your task board is a git repo": the product, then what it is.
  // "Docs — GitKittie": the page, on the site.
  const [first, second] = meta.title.split(' — ')
  const named = second && second !== 'GitKittie'
  return {
    eyebrow: named ? first : 'GitKittie',
    title: named ? second : first,
    description: meta.description,
    app: page.app,
    shot: page.shot,
    device: page.shot ? deviceOf(page.shot) : undefined,
  }
}
