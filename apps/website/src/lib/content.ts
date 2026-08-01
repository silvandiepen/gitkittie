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
export type AppSlug = 'gitfolder' | 'gitkanban' | 'gitbud'

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
