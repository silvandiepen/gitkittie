<script setup lang="ts">
/**
 * @component AppCard
 * One product, as a full-bleed colour panel rather than a card on a background.
 * Sets [data-app] so the panel fills with that product's own hue and everything
 * inside it — badge border, rules, link underline — inherits the contrast text
 * colour from `--color-accent-contrast`.
 */
import GitFolderMark from './GitFolderMark.vue'
import GitKanbanMark from './GitKanbanMark.vue'
import GitBudMark from './GitBudMark.vue'
import type { AppSlug } from '@/lib/content'

defineProps<{
  app: AppSlug
  name: string
  tagline: string
  points: string[]
  to: string
  cta: string
  badge?: string
  /** Mono index shown at the top of the panel, e.g. "01". */
  marker?: string
}>()
</script>

<template>
  <article class="mkt__panel app-panel" :data-app="app">
    <div class="app-panel__head">
      <span v-if="marker" class="mkt__marker">{{ marker }}</span>
      <span v-if="badge" class="mkt__badge">{{ badge }}</span>
    </div>

    <span class="app-panel__mark" aria-hidden="true">
      <GitFolderMark v-if="app === 'gitfolder'" :size="72" />
      <GitKanbanMark v-else-if="app === 'gitkanban'" :size="72" />
      <GitBudMark v-else :size="72" />
    </span>

    <div class="app-panel__copy">
      <h3 class="mkt__display-s">{{ name }}</h3>
      <p class="app-panel__tagline">{{ tagline }}</p>
    </div>

    <ul class="app-panel__points" role="list">
      <li v-for="p in points" :key="p" class="app-panel__point">{{ p }}</li>
    </ul>

    <RouterLink :to="to" class="mkt__link app-panel__cta">
      {{ cta }}
      <svg class="app-panel__arrow" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M2 8h11m-4-4 4 4-4 4" />
      </svg>
    </RouterLink>
  </article>
</template>

<style lang="scss">
.app-panel {
  gap: var(--space);

  // A panel that spans the full grid — the odd one out of three — would
  // otherwise stretch its copy across the whole viewport. The reading measure
  // stays one column wide regardless of how many columns the panel occupies.
  --app-panel-measure: 46ch;

  &__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space);
    max-width: var(--app-panel-measure);
  }

  &__mark {
    display: inline-flex;
    margin-top: auto;
  }

  &__copy {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
    max-width: var(--app-panel-measure);
  }

  &__tagline {
    font-size: var(--font-size-m);
    line-height: 1.45;
    max-width: 30ch;
    color: color-mix(in srgb, currentColor 80%, transparent);
  }

  &__points {
    display: flex;
    flex-direction: column;
    padding: 0;
    max-width: var(--app-panel-measure);
  }

  // The hairline between points is the panel's own text colour, faded — on a
  // filled panel a neutral --color-rule would read as a foreign grey.
  &__point {
    padding: var(--space-s) 0;
    border-top: var(--border-width) solid color-mix(in srgb, currentColor 25%, transparent);
    font-size: var(--font-size-s);
    line-height: var(--line-height-normal);
  }

  &__cta {
    margin-top: var(--space-s);
  }

  &__arrow {
    width: 14px;
    height: 14px;
  }
}
</style>
