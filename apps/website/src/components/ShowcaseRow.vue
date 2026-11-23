<script setup lang="ts">
/**
 * @component ShowcaseRow
 * One feature next to the screenshot that shows it. Rows alternate sides with
 * `flip`, so a run of them reads down the page instead of as a grid of cards.
 *
 * `title` is markdown: wrap the accent phrase in *…*.
 */
import { Markdown } from '@sil/ui'
import AppShot from './AppShot.vue'
import type { Showcase } from '@/lib/content'

defineProps<{
  item: Showcase
  flip?: boolean
}>()
</script>

<template>
  <article class="showcase" :class="[{ 'showcase--flip': flip }, `showcase--${item.shot.device}`]">
    <div class="showcase__copy">
      <span class="mkt__eyebrow">{{ item.eyebrow }}</span>
      <Markdown class="mkt__display-s" tag="h3" inline :content="item.title" />
      <p class="mkt__body">{{ item.text }}</p>
      <ul v-if="item.points?.length" class="showcase__points" role="list">
        <li v-for="p in item.points" :key="p" class="showcase__point">{{ p }}</li>
      </ul>
    </div>

    <div class="showcase__media">
      <AppShot
        :device="item.shot.device"
        :light="item.shot.light"
        :dark="item.shot.dark"
        :alt="item.shot.alt"
        :width="item.shot.width"
        :height="item.shot.height"
      />
    </div>
  </article>
</template>

<style lang="scss">
.showcase {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: clamp(var(--space-l), 6vw, var(--space-xxl));
  align-items: center;

  // A Mac window is wide: give it the larger share of the row.
  @include m(mac) {
    grid-template-columns: minmax(0, 2fr) minmax(0, 3fr);

    &.showcase--flip { grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); }
  }

  @include m(flip) {
    .showcase__copy { order: 2; }
  }

  @include tablet {
    grid-template-columns: 1fr;

    &.showcase--mac,
    &.showcase--mac.showcase--flip { grid-template-columns: 1fr; }

    .showcase__copy { order: 0; }
  }

  &__copy {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  &__media {
    display: flex;
    justify-content: center;
  }

  &__points {
    display: flex;
    flex-direction: column;
    padding: 0;
  }

  &__point {
    display: flex;
    align-items: baseline;
    gap: var(--space-s);
    padding: var(--space-s) 0;
    border-top: var(--border-width) solid var(--color-rule);
    font-size: var(--font-size-s);
    line-height: var(--line-height-normal);
    color: var(--color-muted);

    // The app's status dot, in the one accent.
    &::before {
      content: '';
      flex: 0 0 auto;
      width: var(--space-s);
      height: var(--space-s);
      border-radius: var(--radius-pill);
      background: var(--color-accent);
      transform: translateY(-1px);
    }
  }
}
</style>
