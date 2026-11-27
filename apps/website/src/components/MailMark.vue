<script setup lang="ts">
/**
 * GitKittie Mail app icon derived from project-assets/GitKittie/assets/icon_gitmail.svg.
 * Colours are mapped through the website brand tokens in _variables.scss.
 *
 * The source art shades the envelope flap with a white → grey gradient. A flat
 * `--gb-icon-feature` stands in for it, as on the Bud mark: at mark sizes the
 * gradient reads as one tone anyway, and a flat stroke keeps the mark themeable.
 */
withDefaults(
  defineProps<{
    size?: number | string
    title?: string
  }>(),
  {
    size: 24,
    title: 'GitKittie Mail',
  },
)
</script>

<template>
  <svg
    class="mail-mark"
    :width="size"
    :height="size"
    viewBox="0 0 153 153"
    role="img"
    :aria-label="title"
    xmlns="http://www.w3.org/2000/svg"
  >
    <rect class="mail-mark__background" x="0" y="0" width="153" height="153" />
    <!-- Offset ink plate reads as the window's drop shadow. -->
    <path
      class="mail-mark__ink"
      d="M38,49.5h86c4.42,0,8,3.58,8,8v42.5c0,9.93-8.07,18-18,18h-67c-4.97,0-9-4.03-9-9V57.5c0-4.42,3.58-8,8-8Z"
    />
    <rect class="mail-mark__paper" x="20" y="40" width="103" height="68" rx="9" ry="9" />
    <path class="mail-mark__flap" d="M34,55L66.5,77.5c3,2.1,7,2.1,10,0L109,55" />
  </svg>
</template>

<style lang="scss">
.mail-mark {
  display: block;
  overflow: hidden;
  border-radius: 22%;

  &__background {
    fill: var(--gm);
  }

  &__ink {
    fill: var(--app-icon-ink);
  }

  &__paper {
    fill: var(--app-icon-paper);
  }

  &__flap {
    fill: none;
    stroke: var(--gb-icon-feature);
    stroke-width: 10;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
}
</style>
