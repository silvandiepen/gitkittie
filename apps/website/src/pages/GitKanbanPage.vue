<script setup lang="ts">
/**
 * @view GitKanbanPage
 * GitKittie Kanban product page — shipped on Mac, iPhone and iPad off one App
 * Store record, so both download buttons point at the same id with and without
 * `?mt=12`. Themed to the orange app icon background via data-app="gitkanban".
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
import { gitkanbanMacAppStoreUrl, gitkanbanAppStoreUrl } from '@/links'
import { useContent } from '@/i18n'

interface GitKanbanContent {
  meta: { title: string; description: string }
  hero: { badge: string; title: string; subtitle: string; download: string; downloadIos: string }
  features: { eyebrow: string; title: string; subtitle: string; items: Feature[] }
  status: { badge: string; title: string; text: string; support: string }
  cta: { eyebrow: string; title: string; subtitle: string; download: string; downloadIos: string }
}

const t = useContent<GitKanbanContent>('gitkanban')

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="gitkanban">
      <ProductHero
        app="gitkanban"
        :badge="t.hero.badge"
        :title="t.hero.title"
        :subtitle="t.hero.subtitle"
        mark-title="GitKittie Kanban"
      >
        <a :href="gitkanbanMacAppStoreUrl" class="mkt__btn" target="_blank" rel="noopener">{{ t.hero.download }}</a>
        <a :href="gitkanbanAppStoreUrl" class="mkt__btn mkt__btn--ghost" target="_blank" rel="noopener">{{ t.hero.downloadIos }}</a>
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

      <!-- One record, three platforms; and how you get in without an account -->
      <NotePanel :badge="t.status.badge" :title="t.status.title" :text="t.status.text">
        <ArlezSupport :label="t.status.support" />
      </NotePanel>

      <ClosingBand :eyebrow="t.cta.eyebrow" :title="t.cta.title" :subtitle="t.cta.subtitle">
        <a :href="gitkanbanMacAppStoreUrl" class="mkt__btn mkt__btn--inverse" target="_blank" rel="noopener">{{ t.cta.download }}</a>
        <a :href="gitkanbanAppStoreUrl" class="mkt__btn mkt__btn--ghost" target="_blank" rel="noopener">{{ t.cta.downloadIos }}</a>
      </ClosingBand>
    </div>
  </MarketingLayout>
</template>
