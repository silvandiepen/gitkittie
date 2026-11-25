<script setup lang="ts">
/**
 * @component ProductHero
 * Opening band of a product page. Copy-led and left-aligned. With a `shot` the
 * app's real screenshot runs the width of the page under the copy, and the app
 * icon shrinks to sit above the title, the way an app is named in the Dock; with
 * none, the icon is held large beside the copy.
 *
 * `title` is markdown: wrap the phrase that should take the accent in *…*.
 * Actions go in the default slot so each product can pick its own buttons.
 */
import { Markdown } from '@sil/ui'
import FolderMark from './FolderMark.vue'
import TasksMark from './TasksMark.vue'
import BudMark from './BudMark.vue'
import MailMark from './MailMark.vue'
import AppShot from './AppShot.vue'
import type { AppSlug, Shot } from '@/lib/content'

defineProps<{
  app: AppSlug
  /** Small uppercase label above the title. */
  eyebrow?: string
  /** Status pill — only when the status is real information. */
  badge?: string
  title: string
  subtitle: string
  markTitle: string
  shot?: Shot
}>()
</script>

<template>
  <section class="product-hero" :class="{ 'product-hero--shot': shot }">
    <div class="mkt__container product-hero__inner">
      <div class="product-hero__copy">
        <span v-if="shot" class="product-hero__icon" aria-hidden="true">
          <FolderMark v-if="app === 'folder'" :size="56" :title="markTitle" />
          <TasksMark v-else-if="app === 'tasks'" :size="56" :title="markTitle" />
          <BudMark v-else-if="app === 'bud'" :size="56" :title="markTitle" />
          <MailMark v-else :size="56" :title="markTitle" />
        </span>
        <span v-if="eyebrow" class="mkt__eyebrow">{{ eyebrow }}</span>
        <span v-if="badge" class="mkt__badge">{{ badge }}</span>
        <Markdown class="mkt__display" tag="h1" inline :content="title" />
        <p class="mkt__lead">{{ subtitle }}</p>
        <div class="mkt__actions product-hero__actions">
          <slot />
        </div>
      </div>

      <div v-if="!shot" class="product-hero__art" aria-hidden="true">
        <FolderMark v-if="app === 'folder'" :size="200" :title="markTitle" />
        <TasksMark v-else-if="app === 'tasks'" :size="200" :title="markTitle" />
        <BudMark v-else-if="app === 'bud'" :size="200" :title="markTitle" />
        <MailMark v-else :size="200" :title="markTitle" />
      </div>
    </div>

    <div v-if="shot" class="mkt__container product-hero__shot">
      <AppShot :device="shot.device" :light="shot.light" :dark="shot.dark" :alt="shot.alt" :width="shot.width" :height="shot.height" eager />
    </div>
  </section>
</template>

<style lang="scss">
.product-hero {
  display: flex;
  flex-direction: column;
  gap: clamp(var(--space-l), 6vw, var(--space-xl));
  padding: clamp(var(--space-xl), 10vw, var(--space-xxl)) 0;

  &__inner {
    display: grid;
    grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr);
    gap: var(--space-xl);
    align-items: center;

    @include tablet {
      grid-template-columns: 1fr;
      gap: var(--space-l);
    }
  }

  // With a screenshot the copy has the row to itself.
  @include m(shot) {
    padding-bottom: clamp(var(--space-l), 6vw, var(--space-xl));

    .product-hero__inner { grid-template-columns: minmax(0, 1fr); }
  }

  &__copy {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-l);
  }

  &__icon {
    display: inline-flex;
  }

  &__actions {
    padding-top: var(--space-s);
  }

  &__art {
    display: flex;
    justify-content: flex-end;

    @include tablet { justify-content: flex-start; }
  }
}
</style>
