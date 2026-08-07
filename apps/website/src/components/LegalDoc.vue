<script setup lang="ts">
/**
 * @component LegalDoc
 * Reader layout for the legal pages (Privacy, Terms). The body is markdown from
 * `i18n/pages/<locale>/<name>.md`, rendered through @sil/ui's Markdown — the
 * page passes the source, not HTML.
 */
import { Markdown } from '@sil/ui'

defineProps<{
  title: string
  updated: string
  /** Markdown source for the document body. */
  content: string
}>()
</script>

<template>
  <article class="legal">
    <header class="legal__header">
      <div class="mkt__container-narrow legal__header-inner">
        <span class="mkt__eyebrow">Last updated: {{ updated }}</span>
        <h1 class="mkt__display-s">{{ title }}</h1>
      </div>
    </header>

    <div class="mkt__container-narrow legal__body-wrap">
      <Markdown class="legal__body" tag="div" :content="content" />
    </div>
  </article>
</template>

<style lang="scss">
.legal {
  padding-bottom: var(--space-xxl);

  &__header {
    padding: clamp(var(--space-xl), 8vw, var(--space-xxl)) 0 var(--space-l);
  }

  &__header-inner {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  &__body-wrap {
    padding-top: var(--space-l);
    border-top: var(--border-width) solid var(--color-rule);
  }

  // Rendered markdown: the elements come from the renderer, so bare selectors
  // are the only way to reach them. Everything else on the site uses classes.
  &__body {
    display: flex;
    flex-direction: column;
    gap: var(--space);
    max-width: 68ch;

    h2 {
      padding-top: var(--space-l);
      font-size: var(--font-size-xl);
      font-weight: var(--font-weight-semibold);
      letter-spacing: var(--tracking-heading);
    }

    h3 {
      font-size: var(--font-size-m);
      font-weight: var(--font-weight-semibold);
    }

    p,
    li {
      font-size: var(--font-size-m);
      line-height: var(--line-height-relaxed);
      color: color-mix(in srgb, var(--color-foreground) 78%, transparent);
    }

    ul {
      display: flex;
      flex-direction: column;
      gap: var(--space-s);
      padding-left: var(--space);
    }

    li { list-style: disc; }

    a {
      color: var(--accent-legible);
      text-decoration: underline;
      text-underline-offset: 2px;
    }

    strong { font-weight: var(--font-weight-semibold); }
  }
}
</style>
