<script setup lang="ts">
/**
 * @component AppShot
 * A real screenshot of an app. With both `light` and `dark` it shows the one that
 * matches the site's colour mode, so a visitor in light mode sees the app in light.
 *
 * `device` sets the frame: a Mac capture already carries its window and corners,
 * so it is only lifted off the page; a phone or tablet capture is a bare screen, so
 * it gets the device's rounded corners and the app's hairline.
 */
import { computed } from 'vue'
import type { ShotDevice } from '@/lib/content'

const props = defineProps<{
  device: ShotDevice
  alt: string
  /** The light-mode capture; also used in dark mode when there is no `dark`. */
  light?: string
  dark?: string
  /** Load with the page instead of when scrolled near (the hero shot). */
  eager?: boolean
  /** The file's own pixel size, when it differs from the device's usual one. */
  width?: number
  height?: number
}>()

/** Pixel size of the files in public/screenshots, so the layout does not jump. */
const sizes: Record<ShotDevice, { width: number; height: number }> = {
  mac: { width: 2000, height: 1250 },
  phone: { width: 660, height: 1434 },
  tablet: { width: 1100, height: 1467 },
}

const size = computed(() =>
  props.width && props.height ? { width: props.width, height: props.height } : sizes[props.device],
)
const both = computed(() => Boolean(props.light && props.dark))
const loading = computed(() => (props.eager ? 'eager' : 'lazy'))
</script>

<template>
  <figure class="app-shot" :class="`app-shot--${device}`">
    <img
      v-if="light"
      class="app-shot__img"
      :class="{ 'app-shot__img--light': both }"
      :src="light"
      :alt="alt"
      :width="size.width"
      :height="size.height"
      :loading="loading"
      decoding="async"
    />
    <img
      v-if="dark"
      class="app-shot__img"
      :class="{ 'app-shot__img--dark': both }"
      :src="dark"
      :alt="both ? '' : alt"
      :aria-hidden="both ? 'true' : undefined"
      :width="size.width"
      :height="size.height"
      :loading="loading"
      decoding="async"
    />
  </figure>
</template>

<style lang="scss">
.app-shot {
  margin: 0;
  width: 100%;

  &__img {
    width: 100%;
    height: auto;
  }

  // Exactly one of a light/dark pair is on screen, keyed off the site's mode.
  &__img--dark { display: none; }

  :root[data-theme="dark"] & {
    .app-shot__img--light { display: none; }
    .app-shot__img--dark { display: block; }
  }

  // The Mac window brings its own frame; it only needs lifting off the page.
  @include m(mac) {
    .app-shot__img {
      filter: drop-shadow(var(--shadow-l));
    }
  }

  // A bare screen: the device's corners and the app's hairline around it.
  @include m(phone) {
    max-width: 330px;

    .app-shot__img {
      border-radius: 14% / 6.5%;
      border: var(--border-width) solid var(--color-border);
    }
  }

  @include m(tablet) {
    .app-shot__img {
      border-radius: 4% / 3%;
      border: var(--border-width) solid var(--color-border);
    }
  }
}
</style>
