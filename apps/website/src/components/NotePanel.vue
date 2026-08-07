<script setup lang="ts">
/**
 * @component NotePanel
 * A single aside on a product page — release status, or a capability that needs
 * explaining on its own. Rendered as a filled band in the product's own hue,
 * so it reads as a deliberate interruption of the page rather than a tinted box
 * dropped into it.
 *
 * Actions are optional and go in the default slot.
 */
import { useSlots } from 'vue'

defineProps<{
  badge?: string
  title: string
  text: string
}>()

const slots = useSlots()
</script>

<template>
  <section class="mkt__band mkt__band--accent note-panel">
    <div class="mkt__container note-panel__inner">
      <div class="mkt__section-head">
        <span v-if="badge" class="mkt__badge">{{ badge }}</span>
        <div class="mkt__section-head-copy">
          <h2 class="mkt__display-s">{{ title }}</h2>
          <p class="note-panel__text">{{ text }}</p>
          <div v-if="slots.default" class="mkt__actions note-panel__actions">
            <slot />
          </div>
        </div>
      </div>
    </div>
  </section>
</template>

<style lang="scss">
.note-panel {
  // The band fills with --color-accent and inherits --color-accent-contrast, so
  // the body copy fades against the panel's own text colour, not a page grey.
  &__text {
    font-size: var(--font-size-m);
    line-height: var(--line-height-relaxed);
    max-width: 62ch;
    color: color-mix(in srgb, currentColor 82%, transparent);
  }

  &__actions {
    padding-top: var(--space-s);
  }
}
</style>
