<script setup lang="ts">
/**
 * @view TasksPage
 * GitKittie Tasks product page (the app was called GitKittie Kanban, at /gitkanban,
 * which now redirects here) — shipped on Mac, iPhone and iPad off one App Store record, so both download buttons point at the same id with and without
 * `?mt=12`. Leads with the Mac board and walks through the app in real
 * screenshots, captured from the demo board for the App Store.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ArlezSupport from '@/components/ArlezSupport.vue'
import ProductHero from '@/components/ProductHero.vue'
import NotePanel from '@/components/NotePanel.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import ShowcaseRow from '@/components/ShowcaseRow.vue'
import type { Feature, Shot, Showcase } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { tasksMacAppStoreUrl, tasksAppStoreUrl } from '@/links'
import { useContent } from '@/i18n'

interface TasksContent {
  meta: { title: string; description: string }
  hero: { badge: string; title: string; subtitle: string; download: string; downloadIos: string; shot: Shot }
  showcase: { eyebrow: string; title: string; subtitle: string; items: Showcase[] }
  features: { eyebrow: string; title: string; subtitle: string; items: Feature[] }
  status: { badge: string; title: string; text: string; support: string }
  cta: { eyebrow: string; title: string; subtitle: string; download: string; downloadIos: string }
}

const t = useContent<TasksContent>('tasks')

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="tasks">
      <ProductHero
        app="tasks"
        :badge="t.hero.badge"
        :title="t.hero.title"
        :subtitle="t.hero.subtitle"
        mark-title="GitKittie Tasks"
        :shot="t.hero.shot"
      >
        <a :href="tasksMacAppStoreUrl" class="mkt__btn" target="_blank" rel="noopener">{{ t.hero.download }}</a>
        <a :href="tasksAppStoreUrl" class="mkt__btn mkt__btn--ghost" target="_blank" rel="noopener">{{ t.hero.downloadIos }}</a>
      </ProductHero>

      <!-- The app, in screenshots -->
      <section class="mkt__band mkt__band--surface">
        <div class="mkt__container product__section product__section--showcase">
          <div class="mkt__section-head">
            <span class="mkt__eyebrow">{{ t.showcase.eyebrow }}</span>
            <div class="mkt__section-head-copy">
              <Markdown class="mkt__display-s" tag="h2" inline :content="t.showcase.title" />
              <p class="mkt__body">{{ t.showcase.subtitle }}</p>
            </div>
          </div>
          <ShowcaseRow v-for="(item, i) in t.showcase.items" :key="item.eyebrow" :item="item" :flip="i % 2 === 1" />
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

      <!-- One record, three platforms; and how you get in without an account -->
      <NotePanel :badge="t.status.badge" :title="t.status.title" :text="t.status.text">
        <ArlezSupport :label="t.status.support" />
      </NotePanel>

      <ClosingBand :eyebrow="t.cta.eyebrow" :title="t.cta.title" :subtitle="t.cta.subtitle">
        <a :href="tasksMacAppStoreUrl" class="mkt__btn mkt__btn--inverse" target="_blank" rel="noopener">{{ t.cta.download }}</a>
        <a :href="tasksAppStoreUrl" class="mkt__btn mkt__btn--ghost" target="_blank" rel="noopener">{{ t.cta.downloadIos }}</a>
      </ClosingBand>
    </div>
  </MarketingLayout>
</template>
