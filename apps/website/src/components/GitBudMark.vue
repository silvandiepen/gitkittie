<script setup lang="ts">
/**
 * GitBud app icon derived from project-assets/GitKittie/assets/icon_gitbud.svg.
 * Colours are mapped through the website brand tokens in _variables.scss.
 *
 * The source art shades the face features with a white → grey gradient. A flat
 * `--gb-icon-feature` stands in for it: at mark sizes the gradient reads as one
 * tone anyway, and a flat fill keeps the mark themeable like its siblings.
 */
withDefaults(
  defineProps<{
    size?: number | string
    title?: string
  }>(),
  {
    size: 24,
    title: 'GitBud',
  },
)
</script>

<template>
  <svg
    class="gitbud-mark"
    :width="size"
    :height="size"
    viewBox="0 0 153 153"
    role="img"
    :aria-label="title"
    xmlns="http://www.w3.org/2000/svg"
  >
    <rect class="gitbud-mark__background" x="0" y="0" width="153" height="153" />
    <!-- Offset ink plate reads as the window's drop shadow. -->
    <path
      class="gitbud-mark__ink"
      d="M53,40.5h65c4.42,0,8,3.58,8,8v59.5c0,9.93-8.07,18-18,18h-54c-4.97,0-9-4.03-9-9V48.5c0-4.42,3.58-8,8-8Z"
    />
    <rect class="gitbud-mark__paper" x="36" y="36" width="81" height="81" rx="9" ry="9" />
    <rect
      class="gitbud-mark__feature"
      x="54"
      y="67.5"
      width="18"
      height="9"
      rx="4.5"
      ry="4.5"
      transform="translate(-9 135) rotate(-90)"
    />
    <rect
      class="gitbud-mark__feature"
      x="76.5"
      y="67.5"
      width="18"
      height="9"
      rx="4.5"
      ry="4.5"
      transform="translate(13.5 157.5) rotate(-90)"
    />
    <path class="gitbud-mark__smile" d="M98.55,90c-12.3,12.3-32.25,12.3-44.55,0" />
  </svg>
</template>

<style lang="scss">
.gitbud-mark {
  display: block;
  overflow: hidden;
  border-radius: 22%;

  &__background {
    fill: var(--gb);
  }

  &__ink {
    fill: var(--app-icon-ink);
  }

  &__paper {
    fill: var(--app-icon-paper);
  }

  &__feature {
    fill: var(--gb-icon-feature);
  }

  &__smile {
    fill: none;
    stroke: var(--gb-icon-feature);
    stroke-width: 10;
    stroke-linecap: round;
    stroke-miterlimit: 10;
  }
}
</style>
