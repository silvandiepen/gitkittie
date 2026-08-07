<script setup lang="ts">
/**
 * @view GitFolderPage
 * GitKittie Folder product page — shipped app. Themed to the green app icon
 * background via data-app="gitfolder", which every band inside inherits.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ProductHero from '@/components/ProductHero.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import type { Feature, Step } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { gitfolderMacAppStoreUrl, gitfolderAppStoreUrl } from '@/links'
import { useContent } from '@/i18n'

interface GitFolderContent {
  meta: { title: string; description: string }
  hero: { eyebrow: string; title: string; subtitle: string; download: string; downloadIos: string; docs: string }
  steps: { eyebrow: string; title: string; subtitle: string; items: Step[] }
  features: { eyebrow: string; title: string; subtitle: string; items: Feature[] }
  cta: { eyebrow: string; title: string; subtitle: string; download: string; downloadIos: string; docs: string }
}

const t = useContent<GitFolderContent>('gitfolder')

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="gitfolder">
      <ProductHero
        app="gitfolder"
        :eyebrow="t.hero.eyebrow"
        :title="t.hero.title"
        :subtitle="t.hero.subtitle"
        mark-title="GitKittie Folder"
      >
        <a :href="gitfolderMacAppStoreUrl" class="mkt__btn" target="_blank" rel="noopener">{{ t.hero.download }}</a>
        <a :href="gitfolderAppStoreUrl" class="mkt__btn mkt__btn--ghost" target="_blank" rel="noopener">{{ t.hero.downloadIos }}</a>
        <router-link to="/docs" class="mkt__link">{{ t.hero.docs }}</router-link>
      </ProductHero>

      <!-- Setup -->
      <section class="mkt__band mkt__band--surface">
        <div class="mkt__container product__section">
          <div class="mkt__section-head">
            <span class="mkt__eyebrow">{{ t.steps.eyebrow }}</span>
            <div class="mkt__section-head-copy">
              <Markdown class="mkt__display-s" tag="h2" inline :content="t.steps.title" />
              <p class="mkt__body">{{ t.steps.subtitle }}</p>
            </div>
          </div>

          <ol class="mkt__rows" role="list">
            <li v-for="s in t.steps.items" :key="s.n" class="mkt__row">
              <span class="mkt__marker">{{ s.n }}</span>
              <div class="mkt__row-body">
                <h3 class="mkt__heading">{{ s.title }}</h3>
                <p class="mkt__body">{{ s.desc }}</p>
              </div>
            </li>
          </ol>
        </div>
      </section>

      <!-- Features -->
      <section class="mkt__band mkt__band--paper">
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

      <ClosingBand :eyebrow="t.cta.eyebrow" :title="t.cta.title" :subtitle="t.cta.subtitle">
        <a :href="gitfolderMacAppStoreUrl" class="mkt__btn mkt__btn--inverse" target="_blank" rel="noopener">{{ t.cta.download }}</a>
        <a :href="gitfolderAppStoreUrl" class="mkt__btn mkt__btn--ghost" target="_blank" rel="noopener">{{ t.cta.downloadIos }}</a>
        <router-link to="/docs" class="mkt__link">{{ t.cta.docs }}</router-link>
      </ClosingBand>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.product {
  // Shared by all three product pages: the vertical rhythm between a section's
  // head and its body.
  &__section {
    display: flex;
    flex-direction: column;
    gap: var(--space-xl);
  }
}
</style>
