<script setup lang="ts">
/**
 * @view GitBudPage
 * GitKittie Bud product page — not yet shipped. Framed "In development", with
 * Arlez as the way to be told when it ships or to say what you'd want from it.
 * Themed to the blue app icon background via data-app="gitbud".
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ArlezSupport from '@/components/ArlezSupport.vue'
import ProductHero from '@/components/ProductHero.vue'
import NotePanel from '@/components/NotePanel.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import type { Feature } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface GitBudContent {
  meta: { title: string; description: string }
  hero: { badge: string; title: string; subtitle: string; notify: string }
  features: { eyebrow: string; title: string; subtitle: string; items: Feature[] }
  status: { badge: string; title: string; text: string; notify: string; support: string }
  magic: { badge: string; title: string; text: string }
  cta: { eyebrow: string; title: string; subtitle: string; notify: string }
}

const t = useContent<GitBudContent>('gitbud')

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="gitbud">
      <ProductHero
        app="gitbud"
        :badge="t.hero.badge"
        :title="t.hero.title"
        :subtitle="t.hero.subtitle"
        mark-title="GitKittie Bud"
      >
        <ArlezSupport :label="t.hero.notify" />
      </ProductHero>

      <!-- Features -->
      <section class="mkt__band mkt__band--surface">
        <div class="mkt__container product__section">
          <div class="mkt__section-head">
            <span class="mkt__eyebrow">{{ t.features.eyebrow }}</span>
            <div class="mkt__section-head-copy">
              <Markdown class="mkt__display-s" tag="h2" inline :content="t.features.title" />
              <p class="mkt__body">{{ t.features.subtitle }}</p>
            </div>
          </div>
          <FeatureGrid :features="t.features.items" />
        </div>
      </section>

      <!-- Magic (BYOK) -->
      <NotePanel :badge="t.magic.badge" :title="t.magic.title" :text="t.magic.text" />

      <!-- Where it is today -->
      <section class="mkt__band mkt__band--paper">
        <div class="mkt__container product__section">
          <div class="mkt__section-head">
            <span class="mkt__badge">{{ t.status.badge }}</span>
            <div class="mkt__section-head-copy">
              <h2 class="mkt__display-s">{{ t.status.title }}</h2>
              <p class="mkt__body">{{ t.status.text }}</p>
              <div class="mkt__actions product__note-actions">
                <ArlezSupport :label="t.status.support" />
              </div>
            </div>
          </div>
        </div>
      </section>

      <ClosingBand :eyebrow="t.cta.eyebrow" :title="t.cta.title" :subtitle="t.cta.subtitle">
        <ArlezSupport :label="t.cta.notify" />
      </ClosingBand>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.product {
  &__note-actions {
    padding-top: var(--space-s);
  }
}
</style>
