<script setup lang="ts">
/**
 * @component ProductHero
 * Opening band of a product page. Copy-led and left-aligned, with the app mark
 * held large but quiet beside it — the words carry the page, not the artwork.
 *
 * `title` is markdown: wrap the phrase that should take the accent in *…*.
 * Actions go in the default slot so each product can pick its own buttons.
 */
import { Markdown } from '@sil/ui'
import GitFolderMark from './GitFolderMark.vue'
import GitKanbanMark from './GitKanbanMark.vue'
import GitBudMark from './GitBudMark.vue'
import type { AppSlug } from '@/lib/content'

defineProps<{
  app: AppSlug
  /** Small uppercase label above the title. */
  eyebrow?: string
  /** Status pill — only when the status is real information. */
  badge?: string
  title: string
  subtitle: string
  markTitle: string
}>()
</script>

<template>
  <section class="product-hero">
    <div class="mkt__container product-hero__inner">
      <div class="product-hero__copy">
        <span v-if="eyebrow" class="mkt__eyebrow">{{ eyebrow }}</span>
        <span v-if="badge" class="mkt__badge">{{ badge }}</span>
        <Markdown class="mkt__display" tag="h1" inline :content="title" />
        <p class="mkt__lead">{{ subtitle }}</p>
        <div class="mkt__actions product-hero__actions">
          <slot />
        </div>
      </div>

      <div class="product-hero__art" aria-hidden="true">
        <GitFolderMark v-if="app === 'gitfolder'" :size="200" :title="markTitle" />
        <GitKanbanMark v-else-if="app === 'gitkanban'" :size="200" :title="markTitle" />
        <GitBudMark v-else :size="200" :title="markTitle" />
      </div>
    </div>
  </section>
</template>

<style lang="scss">
.product-hero {
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

  &__copy {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-l);
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
