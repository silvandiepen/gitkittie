<script setup lang="ts">
/**
 * @view HomePage
 * GitKittie family landing page — introduces the umbrella and all three apps.
 *
 * The page opens on the real Tasks window, then states the idea, then the three
 * products as panels the way the apps draw them, then the shared principles as
 * ruled rows, then the closing call on the deepest navy.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import AppCard from '@/components/AppCard.vue'
import AppShot from '@/components/AppShot.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import GitKittieMark from '@/components/GitKittieMark.vue'
import type { Feature, AppCardContent, Shot } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface HomeContent {
  meta: { title: string; description: string }
  hero: {
    eyebrow: string
    title: string
    subtitle: string
    ctaFolder: string
    ctaTasks: string
    ctaBud: string
    shot: Shot
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
            <router-link to="/tasks" class="mkt__btn">{{ t.hero.ctaTasks }}</router-link>
            <router-link to="/folder" class="mkt__btn mkt__btn--ghost">{{ t.hero.ctaFolder }}</router-link>
            <router-link to="/bud" class="mkt__link">{{ t.hero.ctaBud }}</router-link>
          </div>
        </div>
        <div class="mkt__container home__hero-shot">
          <AppShot :device="t.hero.shot.device" :light="t.hero.shot.light" :dark="t.hero.shot.dark" :alt="t.hero.shot.alt" eager />
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

        <div class="mkt__container mkt__panels">
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
        <router-link to="/folder" class="mkt__btn mkt__btn--inverse">{{ t.cta.primary }}</router-link>
        <router-link to="/tasks" class="mkt__btn mkt__btn--ghost">{{ t.cta.secondary }}</router-link>
      </ClosingBand>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.home {
  // ── Hero ───────────────────────────────────────────────────────────────
  &__hero {
    display: flex;
    flex-direction: column;
    gap: clamp(var(--space-l), 6vw, var(--space-xl));
    padding: clamp(var(--space-xl), 10vw, var(--space-xxl)) 0 clamp(var(--space-l), 6vw, var(--space-xl));
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

  // ── Statement ──────────────────────────────────────────────────────────
  // The watermark below is oversized on purpose; the band clips it, so it never
  // reaches up over the screenshot in the hero.
  &__statement {
    overflow: hidden;
  }

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
  &__apps {
    display: flex;
    flex-direction: column;
    gap: var(--space-xl);
    padding-bottom: clamp(var(--space-xl), 9vw, var(--space-xxl));
  }

  &__apps-head {
    padding-top: clamp(var(--space-xl), 9vw, var(--space-xxl));
  }

  // ── Principles ─────────────────────────────────────────────────────────
  &__principles {
    display: flex;
    flex-direction: column;
    gap: var(--space-xl);
  }
}
</style>
