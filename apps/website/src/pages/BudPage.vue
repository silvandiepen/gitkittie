<script setup lang="ts">
/**
 * @view BudPage
 * GitKittie Bud product page — in development on Mac, iPhone and iPad. Leads with the real
 * Mac window, walks through it in screenshots, shows the iPhone undo workflow step by step,
 * and says plainly what is not shipped yet. Arlez is the way to be told when it is.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ArlezSupport from '@/components/ArlezSupport.vue'
import ProductHero from '@/components/ProductHero.vue'
import ShowcaseRow from '@/components/ShowcaseRow.vue'
import WorkflowSteps from '@/components/WorkflowSteps.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import type { Feature, Showcase, Shot, Workflow } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface BudContent {
  meta: { title: string; description: string }
  hero: { badge: string; title: string; subtitle: string; notify: string; shot: Shot }
  showcase: { eyebrow: string; title: string; subtitle: string; items: Showcase[] }
  workflow: Workflow
  features: { eyebrow: string; title: string; subtitle: string; items: Feature[] }
  status: { badge: string; title: string; text: string; notify: string; support: string }
  cta: { eyebrow: string; title: string; subtitle: string; notify: string }
}

const t = useContent<BudContent>('bud')

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="bud">
      <ProductHero
        app="bud"
        :badge="t.hero.badge"
        :title="t.hero.title"
        :subtitle="t.hero.subtitle"
        mark-title="GitKittie Bud"
        :shot="t.hero.shot"
      >
        <ArlezSupport :label="t.hero.notify" />
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

      <!-- A workflow, step by step -->
      <section class="mkt__band mkt__band--paper">
        <div class="mkt__container">
          <WorkflowSteps :workflow="t.workflow" />
        </div>
      </section>

      <!-- Everything it does -->
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

      <!-- Where it is today -->
      <section class="mkt__band mkt__band--paper">
        <div class="mkt__container">
          <div class="mkt__panel product__status">
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
