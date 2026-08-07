<script setup lang="ts">
/**
 * @component ClosingBand
 * The ink band that closes a marketing page. Left-aligned like everything else
 * on the page — a centred closing block is the one place the old layout broke
 * its own alignment, and it read as a template.
 *
 * `title` is markdown: wrap the accent phrase in *…*. Actions go in the slot.
 */
import { Markdown } from '@sil/ui'
import GitKittieMark from './GitKittieMark.vue'

defineProps<{
  eyebrow?: string
  title: string
  subtitle: string
}>()
</script>

<template>
  <section class="mkt__band mkt__band--ink closing-band">
    <div class="mkt__container closing-band__inner">
      <GitKittieMark class="closing-band__watermark" :size="600" aria-hidden="true" />
      <span v-if="eyebrow" class="mkt__eyebrow">{{ eyebrow }}</span>
      <Markdown class="mkt__display" tag="h2" inline :content="title" />
      <p class="mkt__lead">{{ subtitle }}</p>
      <div class="mkt__actions closing-band__actions">
        <slot />
      </div>
    </div>
  </section>
</template>

<style lang="scss">
.closing-band {
  overflow: hidden;

  &__inner {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-l);
    position: relative;
  }

  // Oversized umbrella mark as texture behind the type. It must never compete
  // with the words, hence the very low opacity.
  &__watermark {
    position: absolute;
    right: calc(var(--space-l) * -1);
    top: 50%;
    width: min(42vw, 600px);
    height: auto;
    opacity: 0.07;
    transform: translateY(-50%) rotate(12deg);
    pointer-events: none;

    @include tablet { width: 70vw; }
  }

  &__actions {
    padding-top: var(--space-s);
    position: relative;
  }
}
</style>
