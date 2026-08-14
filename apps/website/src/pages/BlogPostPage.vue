<script setup lang="ts">
/**
 * @view BlogPostPage
 * Renders one article by `:slug`. An unknown slug is not an error page — it
 * falls back to the index, which is the only other place the reader wanted.
 */
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import MarketingLayout from '@/components/MarketingLayout.vue'
import ArticleDoc from '@/components/ArticleDoc.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { usePosts, useRelatedPosts } from '@/lib/posts'
import { useContent } from '@/i18n'

interface BlogContent {
  notFound: string
  backToIndex: string
  relatedHeading: string
}

const t = useContent<BlogContent>('blog')
const route = useRoute()

const posts = usePosts()
const post = computed(() => posts.find((p) => p.slug === String(route.params.slug)))
const related = computed(() => (post.value ? useRelatedPosts(post.value) : []))

// Getters, not values: this component stays mounted across `/blog/:slug`
// navigations, so a snapshot here would leave the previous article's head.
usePageMeta({
  title: () => (post.value ? `${post.value.title} — GitKittie` : 'Writing — GitKittie'),
  description: () => post.value?.description ?? '',
})
</script>

<template>
  <MarketingLayout>
    <ArticleDoc v-if="post" :post="post">
      <template #footer>
        <aside v-if="related.length" class="mkt__container-narrow related">
          <h2 class="mkt__eyebrow">{{ t.relatedHeading }}</h2>
          <ul class="related__list">
            <li v-for="item in related" :key="item.slug">
              <router-link :to="`/blog/${item.slug}`" class="related__link">
                <span class="related__title">{{ item.title }}</span>
                <span class="related__desc">{{ item.description }}</span>
              </router-link>
            </li>
          </ul>
        </aside>
      </template>
    </ArticleDoc>

    <section v-else class="mkt__container-narrow missing">
      <h1 class="mkt__display-s">{{ t.notFound }}</h1>
      <router-link to="/blog" class="mkt__link">{{ t.backToIndex }}</router-link>
    </section>
  </MarketingLayout>
</template>

<style lang="scss">
.related {
  display: flex;
  flex-direction: column;
  gap: var(--space);
  margin-top: var(--space-xl);
  padding-top: var(--space-l);
  border-top: var(--border-width) solid var(--color-rule);

  &__list {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  &__link {
    display: flex;
    flex-direction: column;
    gap: 2px;
    text-decoration: none;
    color: inherit;

    &:hover .related__title { color: var(--accent-legible); }
  }

  &__title {
    font-size: var(--font-size-m);
    font-weight: var(--font-weight-semibold);
    transition: color var(--transition-fast);
  }

  &__desc {
    font-size: var(--font-size-s);
    line-height: var(--line-height-relaxed);
    color: var(--color-muted);
  }
}

.missing {
  display: flex;
  flex-direction: column;
  gap: var(--space);
  padding: clamp(var(--space-xl), 8vw, var(--space-xxl)) 0;
}
</style>
