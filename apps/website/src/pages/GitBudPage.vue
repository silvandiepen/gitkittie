<script setup lang="ts">
/**
 * @view GitBudPage
 * GitBud product page — not yet shipped. Framed "In development" with a notify /
 * star-on-GitHub CTA. Themed to the blue app icon background via data-app="gitbud".
 */
import MarketingLayout from '@/components/MarketingLayout.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import type { Feature } from '@/lib/content'
import GitBudMark from '@/components/GitBudMark.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { githubRepoUrl, gitbudNotify } from '@/links'
import { useContent } from '@/i18n'

interface GitBudContent {
  meta: { title: string; description: string }
  hero: { badge: string; title: string; subtitle: string; notify: string; github: string }
  features: { title: string; subtitle: string; items: Feature[] }
  status: { badge: string; title: string; text: string; notify: string; github: string }
  magic: { badge: string; title: string; text: string; notify: string; github: string }
  cta: { title: string; subtitle: string; notify: string; github: string }
}

const t = useContent<GitBudContent>('gitbud')

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="gitbud">
      <!-- Hero -->
      <section class="mkt__hero">
        <div class="mkt__container mkt__hero-grid">
          <div class="mkt__hero-copy">
            <p class="mkt__eyebrow">
              <span class="mkt__badge">{{ t.hero.badge }}</span>
            </p>
            <h1 class="mkt__hero-title">{{ t.hero.title }}</h1>
            <p class="mkt__hero-subtitle">{{ t.hero.subtitle }}</p>
            <div class="mkt__hero-actions">
              <a :href="gitbudNotify" class="mkt__btn-pill">{{ t.hero.notify }}</a>
              <a :href="githubRepoUrl" class="mkt__btn-outline" target="_blank" rel="noopener">{{ t.hero.github }}</a>
            </div>
          </div>
          <div class="mkt__hero-art">
            <GitBudMark class="mkt__hero-mark" :size="224" title="GitBud" />
          </div>
        </div>
      </section>

      <!-- Features -->
      <section class="mkt__section product__features">
        <div class="mkt__container">
          <div class="mkt__section-head">
            <h2 class="mkt__section-title">{{ t.features.title }}</h2>
            <p class="mkt__section-subtitle">{{ t.features.subtitle }}</p>
          </div>
          <FeatureGrid :features="t.features.items" />
        </div>
      </section>

      <!-- Magic (BYOK) -->
      <section class="mkt__section gb-note">
        <div class="mkt__container-narrow gb-note__inner">
          <span class="mkt__badge">{{ t.magic.badge }}</span>
          <h2 class="gb-note__title">{{ t.magic.title }}</h2>
          <p class="gb-note__text">{{ t.magic.text }}</p>
        </div>
      </section>

      <!-- Status note -->
      <section class="mkt__section gb-note">
        <div class="mkt__container-narrow gb-note__inner">
          <span class="mkt__badge">{{ t.status.badge }}</span>
          <h2 class="gb-note__title">{{ t.status.title }}</h2>
          <p class="gb-note__text">{{ t.status.text }}</p>
          <div class="gb-note__actions">
            <a :href="gitbudNotify" class="mkt__btn-pill">{{ t.status.notify }}</a>
            <a :href="githubRepoUrl" class="mkt__btn-outline" target="_blank" rel="noopener">{{ t.status.github }}</a>
          </div>
        </div>
      </section>

      <!-- CTA -->
      <section class="mkt__cta">
        <div class="mkt__container">
          <h2 class="mkt__cta-title">{{ t.cta.title }}</h2>
          <p class="mkt__cta-subtitle">{{ t.cta.subtitle }}</p>
          <div class="mkt__cta-actions">
            <a :href="gitbudNotify" class="mkt__btn-pill mkt__btn-pill--lg">{{ t.cta.notify }}</a>
            <a :href="githubRepoUrl" class="mkt__btn-outline mkt__btn-outline--inverse" target="_blank" rel="noopener">{{ t.cta.github }}</a>
          </div>
        </div>
      </section>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.gb-note {
  &__inner {
    text-align: center;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: var(--space);
    padding: var(--space-xl) var(--space-l);
    border-radius: var(--border-radius-xxl);
    background: var(--color-accent-tint);
    border: var(--border-width) solid color-mix(in srgb, var(--color-accent) 24%, transparent);
  }

  &__title {
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-bold);
    letter-spacing: -0.01em;
  }

  &__text {
    font-size: var(--font-size);
    color: var(--color-muted);
    line-height: var(--line-height-relaxed);
    max-width: 560px;
  }

  &__actions {
    display: flex;
    gap: var(--space-s);
    flex-wrap: wrap;
    justify-content: center;
  }
}
</style>
