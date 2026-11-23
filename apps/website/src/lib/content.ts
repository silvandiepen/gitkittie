// Shared content-shape types used by pages + content JSON.

/** A single feature card (icon glyph name + title + description). */
export interface Feature {
  icon: string
  title: string
  desc: string
}

/** A numbered how-it-works step. */
export interface Step {
  n: string
  title: string
  desc: string
}

/** The products the site themes itself for — drives [data-app] and the marks. */
export type AppSlug = 'folder' | 'tasks' | 'bud'

/** A home-page product card. */
export interface AppCardContent {
  app: AppSlug
  name: string
  tagline: string
  points: string[]
  to: string
  cta: string
  badge?: string
}

/** Which frame a screenshot gets (see AppShot). */
export type ShotDevice = 'mac' | 'phone' | 'tablet'

/** A screenshot as the content files describe it: paths under /public, and words. */
export interface Shot {
  device: ShotDevice
  light?: string
  dark?: string
  alt: string
}

/** One feature shown with its screenshot. */
export interface Showcase {
  eyebrow: string
  title: string
  text: string
  points?: string[]
  shot: Shot
}
