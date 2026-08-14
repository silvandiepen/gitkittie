<script setup lang="ts">
/**
 * @component ArticleDoc
 * Reader layout for a blog article. Same contract as LegalDoc — the page hands
 * over Markdown source, not HTML, and @sil/ui's Markdown renders it — but with
 * an article header (date, reading time) and room for code blocks, which the
 * legal pages never carry.
 */
import { Markdown } from '@sil/ui'
import { formatPostDate, type Post } from '@/lib/posts'

defineProps<{ post: Post }>()
</script>

<template>
  <article class="article" :data-app="post.app">
    <header class="article__header">
      <div class="mkt__container-narrow article__header-inner">
        <router-link to="/blog" class="mkt__link article__back">← All writing</router-link>
        <span class="mkt__eyebrow">
          {{ formatPostDate(post.date) }} · {{ post.readingMinutes }} min read
        </span>
        <h1 class="mkt__display-s">{{ post.title }}</h1>
        <p class="mkt__lead">{{ post.description }}</p>
      </div>
    </header>

    <div class="mkt__container-narrow article__body-wrap">
      <Markdown class="article__body" tag="div" :content="post.body" />
    </div>

    <slot name="footer" />
  </article>
</template>

<style lang="scss">
.article {
  padding-bottom: var(--space-xxl);

  &__header {
    padding: clamp(var(--space-xl), 8vw, var(--space-xxl)) 0 var(--space-l);
  }

  &__header-inner {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  &__back {
    width: fit-content;
    font-size: var(--font-size-s);
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
      padding-top: var(--space-s);
      font-size: var(--font-size-m);
      font-weight: var(--font-weight-semibold);
    }

    p,
    li {
      font-size: var(--font-size-m);
      line-height: var(--line-height-relaxed);
      color: color-mix(in srgb, var(--color-foreground) 78%, transparent);
    }

    ul,
    ol {
      display: flex;
      flex-direction: column;
      gap: var(--space-s);
      padding-left: var(--space);
    }

    ul li { list-style: disc; }
    ol li { list-style: decimal; }

    a {
      color: var(--accent-legible);
      text-decoration: underline;
      text-underline-offset: 2px;
    }

    strong { font-weight: var(--font-weight-semibold); }

    blockquote {
      padding-left: var(--space);
      border-left: 2px solid var(--accent-legible);
      color: var(--color-muted);
      font-style: italic;
    }

    // Inline code sits inside a sentence; a fenced block is its own object and
    // is allowed to scroll sideways rather than wrap a folder tree mid-path.
    code {
      font-family: var(--font-family-mono, ui-monospace, monospace);
      font-size: 0.9em;
      padding: 0.15em 0.4em;
      border-radius: var(--border-radius-s);
      background: color-mix(in srgb, var(--color-foreground) 8%, transparent);
    }

    pre {
      overflow-x: auto;
      padding: var(--space);
      border-radius: var(--border-radius);
      border: var(--border-width) solid var(--color-rule);
      background: color-mix(in srgb, var(--color-foreground) 5%, transparent);

      code {
        padding: 0;
        background: none;
        font-size: var(--font-size-s);
        line-height: var(--line-height-relaxed);
      }
    }

    hr {
      border: 0;
      border-top: var(--border-width) solid var(--color-rule);
      margin: var(--space) 0;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: var(--font-size-s);

      th,
      td {
        padding: var(--space-s);
        border-bottom: var(--border-width) solid var(--color-rule);
        text-align: left;
      }

      th { font-weight: var(--font-weight-semibold); }
    }
  }
}
</style>
