<script setup lang="ts">
/**
 * @view SupportPage
 * Support and troubleshooting for the GitKittie apps.
 *
 * Each app's section sets its own [data-app], so the heading rule and links
 * pick up that product's hue as you scroll through. All prose is markdown.
 */
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ArlezSupport from '@/components/ArlezSupport.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface StepItem { title: string; desc: string }
interface SupportContent {
  meta: { title: string; description: string }
  eyebrow: string
  title: string
  intro: string
  gitfolder: {
    heading: string
    setup: { title: string; steps: StepItem[] }
    common: { title: string; items: StepItem[] }
  }
  gitkanban: { heading: string; title: string; body: string; action: string }
  gitbud: { heading: string; title: string; body: string; action: string }
  stillStuck: { title: string; body: string; action: string }
}

const t = useContent<SupportContent>('support')

usePageMeta({ title: t.meta.title, description: t.meta.description })

/** 1-based, zero-padded — matches the mono markers used across the site. */
function marker(i: number): string {
  return String(i + 1).padStart(2, '0')
}
</script>

<template>
  <MarketingLayout>
    <div class="support">
      <header class="support__header">
        <div class="mkt__container support__header-inner">
          <span class="mkt__eyebrow">{{ t.eyebrow }}</span>
          <h1 class="mkt__display-s">{{ t.title }}</h1>
          <p class="mkt__lead">{{ t.intro }}</p>
        </div>
      </header>

      <!-- GitKittie Folder -->
      <section class="support__app" data-app="gitfolder">
        <div class="mkt__container support__app-inner">
          <h2 class="support__app-heading">{{ t.gitfolder.heading }}</h2>

          <div class="support__group">
            <h3 class="mkt__heading">{{ t.gitfolder.setup.title }}</h3>
            <ol class="mkt__rows" role="list">
              <li v-for="(step, i) in t.gitfolder.setup.steps" :key="step.title" class="mkt__row">
                <span class="mkt__marker">{{ marker(i) }}</span>
                <div class="mkt__row-body">
                  <h4 class="support__item-title">{{ step.title }}</h4>
                  <Markdown class="support__prose" tag="div" :content="step.desc" />
                </div>
              </li>
            </ol>
          </div>

          <div class="support__group">
            <h3 class="mkt__heading">{{ t.gitfolder.common.title }}</h3>
            <div class="mkt__rows">
              <div v-for="item in t.gitfolder.common.items" :key="item.title" class="mkt__row">
                <h4 class="support__item-title">{{ item.title }}</h4>
                <div class="mkt__row-body">
                  <Markdown class="support__prose" tag="div" :content="item.desc" />
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <!-- GitKittie Kanban -->
      <section class="support__app" data-app="gitkanban">
        <div class="mkt__container support__app-inner">
          <h2 class="support__app-heading">{{ t.gitkanban.heading }}</h2>
          <div class="support__group">
            <h3 class="mkt__heading">{{ t.gitkanban.title }}</h3>
            <Markdown class="support__prose" tag="div" :content="t.gitkanban.body" />
            <div class="mkt__actions support__actions">
              <ArlezSupport :label="t.gitkanban.action" />
            </div>
          </div>
        </div>
      </section>

      <!-- GitKittie Bud -->
      <section class="support__app" data-app="gitbud">
        <div class="mkt__container support__app-inner">
          <h2 class="support__app-heading">{{ t.gitbud.heading }}</h2>
          <div class="support__group">
            <h3 class="mkt__heading">{{ t.gitbud.title }}</h3>
            <Markdown class="support__prose" tag="div" :content="t.gitbud.body" />
            <div class="mkt__actions support__actions">
              <ArlezSupport :label="t.gitbud.action" />
            </div>
          </div>
        </div>
      </section>

      <!-- Still stuck -->
      <section class="mkt__band mkt__band--ink">
        <div class="mkt__container support__group">
          <h2 class="mkt__display-s">{{ t.stillStuck.title }}</h2>
          <Markdown class="support__prose support__prose--inverse" tag="div" :content="t.stillStuck.body" />
          <div class="mkt__actions support__actions">
            <ArlezSupport :label="t.stillStuck.action" />
          </div>
        </div>
      </section>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.support {
  @include e(header) {
    padding: clamp(var(--space-xl), 8vw, var(--space-xxl)) 0 var(--space-xl);
  }

  @include e(header-inner) {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  @include e(app) {
    padding-bottom: var(--space-xl);
  }

  @include e(app-inner) {
    display: flex;
    flex-direction: column;
    gap: var(--space-l);
  }

  // The product's name sits on its own coloured rule — enough to mark whose
  // section this is without a tinted pill around it.
  @include e(app-heading) {
    padding-bottom: var(--space-s);
    border-bottom: 3px solid var(--color-accent);
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-semibold);
    letter-spacing: var(--tracking-heading);
    width: fit-content;
  }

  @include e(actions) {
    padding-top: var(--space-s);
  }

  @include e(group) {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  @include e(item-title) {
    font-size: var(--font-size-m);
    font-weight: var(--font-weight-semibold);
  }

  // Rendered markdown — see the same note on DocsPage.
  @include e(prose) {
    font-size: var(--font-size-s);
    line-height: var(--line-height-relaxed);
    color: color-mix(in srgb, var(--color-foreground) 78%, transparent);
    max-width: 62ch;

    p + p { margin-top: var(--space-s); }

    code {
      padding: 0 var(--space-xs);
      background: var(--surface-raised);
      border: var(--border-width) solid var(--color-border-light);
      font-family: var(--font-family-monospace);
      font-size: var(--font-size-xs);
    }

    a {
      color: var(--accent-legible);
      text-decoration: underline;
      text-underline-offset: 2px;
    }

    // On the ink band the copy fades toward paper, not toward ink.
    @include m(inverse) {
      color: color-mix(in srgb, var(--color-light) 78%, transparent);

      a { color: var(--color-light); }
    }
  }
}
</style>
