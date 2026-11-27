<script setup lang="ts">
/**
 * @component AppCard
 * One product, as a panel the way the apps draw one: a step lighter than the
 * window, one hairline, the app's icon at the top. The icon is the product's
 * colour; the panel itself stays in the family's navy and its one accent.
 */
import FolderMark from './FolderMark.vue'
import TasksMark from './TasksMark.vue'
import BudMark from './BudMark.vue'
import MailMark from './MailMark.vue'
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
  <article class="mkt__panel app-panel">
    <div class="app-panel__head">
      <span v-if="marker" class="mkt__marker">{{ marker }}</span>
      <span v-if="badge" class="mkt__badge">{{ badge }}</span>
    </div>

    <span class="app-panel__mark" aria-hidden="true">
      <FolderMark v-if="app === 'folder'" :size="72" />
      <TasksMark v-else-if="app === 'tasks'" :size="72" />
      <BudMark v-else-if="app === 'bud'" :size="72" />
      <MailMark v-else :size="72" />
    </span>

    <div class="app-panel__copy">
      <h3 class="app-panel__name">{{ name }}</h3>
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

  &__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space);
  }

  &__mark {
    display: inline-flex;
    padding-top: var(--space-s);
  }

  &__copy {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
  }

  &__name {
    font-size: var(--font-size-xl);
    font-weight: var(--font-weight-semibold);
    letter-spacing: var(--tracking-heading);
    line-height: var(--line-height-tight);
  }

  &__tagline {
    font-size: var(--font-size-m);
    line-height: 1.45;
    color: var(--color-muted);
  }

  &__points {
    display: flex;
    flex-direction: column;
    padding: 0;
  }

  &__point {
    padding: var(--space-s) 0;
    border-top: var(--border-width) solid var(--color-rule);
    font-size: var(--font-size-s);
    line-height: var(--line-height-normal);
    color: var(--color-muted);
  }

  // The link sits on the panel's bottom edge, so three panels line up.
  &__cta {
    margin-top: auto;
    color: var(--accent-legible);

    &:hover { color: var(--accent-legible); }
  }

  &__arrow {
    width: 14px;
    height: 14px;
  }
}
</style>
