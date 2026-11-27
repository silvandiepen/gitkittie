<script setup lang="ts">
/**
 * @component ShareCard
 * The 1200 × 630 picture a shared link shows. Drawn with the site's own marks, type and
 * navy, with the app's real screenshot running off the edge, then captured by
 * `npm run og`. Only `og.html` renders it.
 */
import { computed } from 'vue'
import FolderMark from '@/components/FolderMark.vue'
import TasksMark from '@/components/TasksMark.vue'
import BudMark from '@/components/BudMark.vue'
import MailMark from '@/components/MailMark.vue'
import GitKittieMark from '@/components/GitKittieMark.vue'
import { siteOrigin } from '@/links'
import type { ShareCardContent } from './cards'

const props = defineProps<{ card: ShareCardContent }>()

/** Longer titles step down a size so every one fits in three lines. */
const titleSize = computed(() => {
  const length = props.card.title.length
  if (length <= 40) return 'l'
  if (length <= 70) return 'm'
  return 's'
})

const host = siteOrigin.replace(/^https?:\/\//, '')
</script>

<template>
  <div class="share-card" :class="[`share-card--${card.device ?? 'none'}`, `share-card--title-${titleSize}`]">
    <div class="share-card__copy">
      <div class="share-card__brand">
        <FolderMark v-if="card.app === 'folder'" :size="52" />
        <TasksMark v-else-if="card.app === 'tasks'" :size="52" />
        <BudMark v-else-if="card.app === 'bud'" :size="52" />
        <MailMark v-else-if="card.app === 'mail'" :size="52" />
        <GitKittieMark v-else :size="52" />
        <span class="share-card__eyebrow">{{ card.eyebrow }}</span>
      </div>
      <h1 class="share-card__title">{{ card.title }}</h1>
      <p class="share-card__description">{{ card.description }}</p>
      <span class="share-card__host">{{ host }}</span>
    </div>

    <img v-if="card.shot" class="share-card__shot" :src="card.shot" alt="" />
  </div>
</template>

<style lang="scss">
body {
  margin: 0;
}

.share-card {
  position: relative;
  overflow: hidden;
  width: 1200px;
  height: 630px;
  box-sizing: border-box;
  padding: 64px;
  background: var(--color-background);
  color: var(--color-foreground);
  font-family: var(--font-family-body);

  &__copy {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    gap: 24px;
    width: 1072px;
    height: 100%;
  }

  // The copy keeps to the left of the screenshot.
  @include m(mac) { .share-card__copy { width: 500px; } }
  @include m(tablet) { .share-card__copy { width: 560px; } }
  @include m(phone) { .share-card__copy { width: 660px; } }

  &__brand {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  &__eyebrow {
    font-size: 18px;
    font-weight: var(--font-weight-semibold);
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-muted);
  }

  &__title {
    margin: 0;
    font-weight: var(--font-weight-bold);
    letter-spacing: -0.02em;
    line-height: 1.08;
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 4;
    overflow: hidden;
  }

  @include m(title-l) { .share-card__title { font-size: 60px; } }
  @include m(title-m) { .share-card__title { font-size: 48px; } }
  @include m(title-s) { .share-card__title { font-size: 40px; } }

  &__description {
    margin: 0;
    font-size: 22px;
    line-height: 1.45;
    color: var(--color-muted);
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 3;
    overflow: hidden;
  }

  &__host {
    margin-top: auto;
    font-size: 20px;
    font-weight: var(--font-weight-medium);
    color: var(--color-subtle);
  }

  // The screenshot runs off the edge of the card, like a window behind the copy.
  &__shot {
    position: absolute;
    box-shadow: 0 24px 64px rgb(0 0 0 / 45%);
  }

  @include m(mac) {
    .share-card__shot {
      top: 96px;
      left: 612px;
      width: 840px;
      border-radius: 12px;
    }
  }

  @include m(tablet) {
    .share-card__shot {
      top: 72px;
      left: 700px;
      width: 460px;
      border-radius: 18px;
    }
  }

  @include m(phone) {
    .share-card__shot {
      top: 64px;
      left: 800px;
      width: 330px;
      border-radius: 46px;
    }
  }
}
</style>
