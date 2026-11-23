<script setup lang="ts">
/**
 * @component NotePanel
 * A single aside on a product page — release status, or a capability that needs
 * explaining on its own. One panel on the window, the way the app shows a
 * notice: a step lighter, one hairline, the badge in the accent tint.
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
  <section class="mkt__band mkt__band--paper note-panel">
    <div class="mkt__container">
      <div class="mkt__panel note-panel__inner">
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
    </div>
  </section>
</template>

<style lang="scss">
.note-panel {
  &__text {
    font-size: var(--font-size-m);
    line-height: var(--line-height-relaxed);
    max-width: 62ch;
    color: var(--color-muted);
  }

  &__actions {
    padding-top: var(--space-s);
  }
}
</style>
