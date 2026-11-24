<script setup lang="ts">
/**
 * @view BlogIndexPage
 * Index of long-form writing. Articles are Markdown files under
 * `i18n/posts/<locale>/`; this page only lists what the registry finds.
 */
import MarketingLayout from '@/components/MarketingLayout.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { usePosts, formatPostDate } from '@/lib/posts'
import { useContent } from '@/i18n'
import { shareImagePath } from '@/lib/seo'

interface BlogContent {
  meta: { title: string; description: string }
  eyebrow: string
  title: string
  lead: string
  empty: string
  readMore: string
}

const t = useContent<BlogContent>('blog')
const posts = usePosts()

usePageMeta({ title: t.meta.title, description: t.meta.description })
</script>

<template>
  <MarketingLayout>
    <section class="blog">
      <header class="blog__header">
        <div class="mkt__container-narrow blog__header-inner">
          <span class="mkt__eyebrow">{{ t.eyebrow }}</span>
          <h1 class="mkt__display-s">{{ t.title }}</h1>
          <p class="mkt__lead">{{ t.lead }}</p>
        </div>
      </header>

      <div class="mkt__container-narrow blog__list-wrap">
        <p v-if="!posts.length" class="mkt__body">{{ t.empty }}</p>

        <ol v-else class="blog__list">
          <li v-for="post in posts" :key="post.slug" class="blog__item" :data-app="post.app">
            <router-link :to="`/blog/${post.slug}`" class="blog__item-link">
              <!-- The article's share card: the same picture a shared link shows. -->
              <img
                class="blog__item-card"
                :src="shareImagePath(`/blog/${post.slug}`)"
                :alt="post.shotAlt"
                width="1200"
                height="630"
                loading="lazy"
                decoding="async"
              />
              <span class="mkt__eyebrow">
                {{ formatPostDate(post.date) }} · {{ post.readingMinutes }} min read
              </span>
              <h2 class="mkt__heading blog__item-title">{{ post.title }}</h2>
              <p class="mkt__body blog__item-desc">{{ post.description }}</p>
              <span class="blog__item-more">{{ t.readMore }} →</span>
            </router-link>
          </li>
        </ol>
      </div>
    </section>
  </MarketingLayout>
</template>

<style lang="scss">
.blog {
  padding-bottom: var(--space-xxl);

  &__header {
    padding: clamp(var(--space-xl), 8vw, var(--space-xxl)) 0 var(--space-l);
  }

  &__header-inner {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  &__list-wrap {
    padding-top: var(--space-l);
    border-top: var(--border-width) solid var(--color-rule);
  }

  &__list {
    display: flex;
    flex-direction: column;
  }

  &__item + &__item {
    border-top: var(--border-width) solid var(--color-rule);
  }

  &__item-link {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
    padding: var(--space-l) 0;
    text-decoration: none;
    color: inherit;

    &:hover .blog__item-title { color: var(--accent-legible); }
    &:hover .blog__item-card { border-color: var(--accent-legible); }
    &:hover .blog__item-more { gap: var(--space); }
  }

  &__item-card {
    width: 100%;
    height: auto;
    margin-bottom: var(--space-s);
    border-radius: var(--radius-shot);
    border: var(--border-width) solid var(--color-rule);
    transition: border-color var(--transition-fast);
  }

  &__item-title {
    transition: color var(--transition-fast);
  }

  &__item-desc {
    max-width: 60ch;
  }

  &__item-more {
    font-size: var(--font-size-s);
    font-weight: var(--font-weight-semibold);
    color: var(--accent-legible);
  }
}
</style>
