<script setup lang="ts">
/**
 * @view HomePage
 * GitKittie family landing page — introduces the umbrella and all three apps.
 *
 * The page reads as a sequence of full-bleed bands rather than cards on a
 * background: statement, then the three products as their own colour panels,
 * then the shared principles as ruled rows, then an ink closing call.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import AppCard from '@/components/AppCard.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import GitKittieMark from '@/components/GitKittieMark.vue'
import type { Feature, AppCardContent } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface HomeContent {
  meta: { title: string; description: string }
  hero: {
    eyebrow: string
    title: string
    subtitle: string
    ctaGitfolder: string
    ctaGitkanban: string
    ctaGitbud: string
  }
  statement: { eyebrow: string; text: string }
  apps: { eyebrow: string; title: string; subtitle: string; items: AppCardContent[] }
  principles: { eyebrow: string; title: string; subtitle: string; features: Feature[] }
  cta: { eyebrow: string; title: string; subtitle: string; primary: string; secondary: string }
}

const t = useContent<HomeContent>('home')

usePageMeta({ title: t.meta.title, description: t.meta.description })

/** Panels are numbered in reading order, zero-padded. */
function marker(i: number): string {
  return String(i + 1).padStart(2, '0')
}
</script>

<template>
  <MarketingLayout>
    <div class="mkt home">
      <!-- Hero -->
      <section class="home__hero">
        <div class="mkt__container home__hero-inner">
          <span class="mkt__eyebrow">{{ t.hero.eyebrow }}</span>
          <Markdown class="mkt__display" tag="h1" inline :content="t.hero.title" />
          <p class="mkt__lead">{{ t.hero.subtitle }}</p>
          <div class="mkt__actions home__hero-actions">
            <router-link to="/gitfolder" class="mkt__btn home__btn--gf">{{ t.hero.ctaGitfolder }}</router-link>
            <router-link to="/gitkanban" class="mkt__btn home__btn--gk">{{ t.hero.ctaGitkanban }}</router-link>
            <router-link to="/gitbud" class="mkt__btn home__btn--gb">{{ t.hero.ctaGitbud }}</router-link>
          </div>
        </div>
      </section>

      <!-- Statement -->
      <section class="mkt__band mkt__band--surface home__statement">
        <div class="mkt__container home__statement-inner">
          <GitKittieMark class="home__watermark" :size="520" aria-hidden="true" />
          <span class="mkt__eyebrow">{{ t.statement.eyebrow }}</span>
          <p class="mkt__display-s home__statement-text">{{ t.statement.text }}</p>
        </div>
      </section>

      <!-- Apps -->
      <section class="home__apps">
        <div class="mkt__container home__apps-head">
          <div class="mkt__section-head">
            <span class="mkt__eyebrow">{{ t.apps.eyebrow }}</span>
            <div class="mkt__section-head-copy">
              <Markdown class="mkt__display-s" tag="h2" inline :content="t.apps.title" />
              <p class="mkt__body">{{ t.apps.subtitle }}</p>
            </div>
          </div>
        </div>

        <div class="mkt__panels home__panels">
          <AppCard
            v-for="(item, i) in t.apps.items"
            :key="item.app"
            :app="item.app"
            :name="item.name"
            :tagline="item.tagline"
            :points="item.points"
            :to="item.to"
            :cta="item.cta"
            :badge="item.badge"
            :marker="marker(i)"
          />
        </div>
      </section>

      <!-- Shared principles -->
      <section class="mkt__band mkt__band--paper">
        <div class="mkt__container home__principles">
          <div class="mkt__section-head">
            <span class="mkt__eyebrow">{{ t.principles.eyebrow }}</span>
            <div class="mkt__section-head-copy">
              <Markdown class="mkt__display-s" tag="h2" inline :content="t.principles.title" />
              <p class="mkt__body">{{ t.principles.subtitle }}</p>
            </div>
          </div>
          <FeatureGrid :features="t.principles.features" />
        </div>
      </section>

      <!-- Closing call -->
      <ClosingBand :eyebrow="t.cta.eyebrow" :title="t.cta.title" :subtitle="t.cta.subtitle">
        <router-link to="/gitfolder" class="mkt__btn mkt__btn--inverse">{{ t.cta.primary }}</router-link>
        <router-link to="/gitkanban" class="mkt__btn mkt__btn--ghost">{{ t.cta.secondary }}</router-link>
      </ClosingBand>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.home {
  // ── Hero ───────────────────────────────────────────────────────────────
  &__hero {
    padding: clamp(var(--space-xl), 10vw, var(--space-xxl)) 0;
  }

  &__hero-inner {
    display: flex;
    flex-direction: column;
    gap: var(--space-l);
    align-items: flex-start;
  }

  &__hero-actions {
    padding-top: var(--space);
  }

  // Each hero button carries its own product's hue, which is the one place on
  // the page where all three appear at once.
  &__btn--gf {
    background: var(--gf-dark);
    color: var(--color-light);

    &:hover { background: var(--gf); color: var(--color-dark); }
  }

  &__btn--gk {
    background: var(--gk-dark);
    color: var(--color-light);

    &:hover { background: var(--gk); color: var(--color-dark); }
  }

  &__btn--gb {
    background: var(--gb-dark);
    color: var(--color-light);

    &:hover { background: var(--gb); color: var(--color-dark); }
  }

  // ── Statement ──────────────────────────────────────────────────────────
  &__statement-inner {
    display: flex;
    flex-direction: column;
    gap: var(--space-l);
    position: relative;
  }

  &__statement-text {
    max-width: 24ch;
    position: relative;
  }

  // The umbrella mark, oversized and barely there. It sits behind the type as
  // texture, so it must never win against the words.
  &__watermark {
    position: absolute;
    right: calc(var(--space-xl) * -1);
    bottom: calc(var(--space-xl) * -1);
    width: min(38vw, 520px);
    height: auto;
    opacity: 0.05;
    transform: rotate(-12deg);
    pointer-events: none;

    @include tablet { width: 60vw; }
  }

  // ── Apps ───────────────────────────────────────────────────────────────
  &__apps-head {
    padding: clamp(var(--space-xl), 9vw, var(--space-xxl)) var(--space-l);
  }

  // Three products in a two-up grid leaves one empty cell; letting the last
  // panel span both columns closes it rather than leaving a hole.
  &__panels {
    > :last-child:nth-child(odd) {
      grid-column: 1 / -1;
    }

    @include tablet {
      > :last-child:nth-child(odd) { grid-column: auto; }
    }
  }

  // ── Principles ─────────────────────────────────────────────────────────
  &__principles {
    display: flex;
    flex-direction: column;
    gap: var(--space-xl);
  }
}
</style>
