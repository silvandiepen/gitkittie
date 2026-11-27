<script setup lang="ts">
/**
 * @view MailPage
 * GitKittie Mail product page — in development, Mac first. There are no screenshots
 * yet, so the hero holds the icon large beside the copy, and the page walks through
 * what is built as ruled feature rows. Everything here is in the app today; what is
 * not is listed plainly under "Not in it yet". Arlez is the way to be told when it ships.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ArlezSupport from '@/components/ArlezSupport.vue'
import ProductHero from '@/components/ProductHero.vue'
import ClosingBand from '@/components/ClosingBand.vue'
import FeatureGrid from '@/components/FeatureGrid.vue'
import type { Feature } from '@/lib/content'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface FeatureSection {
  eyebrow: string
  title: string
  subtitle: string
  items: Feature[]
}

interface MailContent {
  meta: { title: string; description: string }
  hero: { badge: string; title: string; subtitle: string; notify: string }
  inbox: FeatureSection
  everyday: FeatureSection
  files: FeatureSection
  safety: FeatureSection
  status: { badge: string; title: string; text: string; comingTitle: string; coming: string[]; support: string }
  cta: { eyebrow: string; title: string; subtitle: string; notify: string }
}

const t = useContent<MailContent>('mail')

usePageMeta({ title: t.meta.title, description: t.meta.description })

/** The feature sections in reading order, alternating band surfaces. */
const sections: Array<{ key: string; band: 'surface' | 'paper'; content: FeatureSection }> = [
  { key: 'inbox', band: 'surface', content: t.inbox },
  { key: 'everyday', band: 'paper', content: t.everyday },
  { key: 'files', band: 'surface', content: t.files },
  { key: 'safety', band: 'paper', content: t.safety },
]
</script>

<template>
  <MarketingLayout>
    <div class="mkt product" data-app="mail">
      <ProductHero
        app="mail"
        :badge="t.hero.badge"
        :title="t.hero.title"
        :subtitle="t.hero.subtitle"
        mark-title="GitKittie Mail"
      >
        <ArlezSupport :label="t.hero.notify" />
      </ProductHero>

      <section
        v-for="section in sections"
        :key="section.key"
        class="mkt__band"
        :class="`mkt__band--${section.band}`"
      >
        <div class="mkt__container product__section">
          <div class="mkt__section-head">
            <span class="mkt__eyebrow">{{ section.content.eyebrow }}</span>
            <div class="mkt__section-head-copy">
              <Markdown class="mkt__display-s" tag="h2" inline :content="section.content.title" />
              <p class="mkt__body">{{ section.content.subtitle }}</p>
            </div>
          </div>
          <FeatureGrid :features="section.content.items" />
        </div>
      </section>

      <!-- Where it is today, and what is not in it -->
      <section class="mkt__band mkt__band--surface">
        <div class="mkt__container">
          <div class="mkt__panel product__status">
            <div class="mkt__section-head">
              <span class="mkt__badge">{{ t.status.badge }}</span>
              <div class="mkt__section-head-copy">
                <h2 class="mkt__display-s">{{ t.status.title }}</h2>
                <p class="mkt__body">{{ t.status.text }}</p>
                <h3 class="mkt__heading mail-status__coming-title">{{ t.status.comingTitle }}</h3>
                <ul class="mail-status__coming" role="list">
                  <li v-for="item in t.status.coming" :key="item" class="mail-status__coming-item">{{ item }}</li>
                </ul>
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

.mail-status {
  &__coming-title {
    padding-top: var(--space-s);
  }

  &__coming {
    display: flex;
    flex-direction: column;
    gap: var(--space-xs);
    padding-left: var(--space);
    list-style: disc;
    color: var(--color-muted);
    font-size: var(--font-size-s);
    line-height: var(--line-height-relaxed);
  }
}
</style>
