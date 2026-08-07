<script setup lang="ts">
/**
 * @view TermsPage
 * Terms & Conditions for the GitKittie apps. Body prose lives in
 * i18n/pages/<locale>/terms.md and is rendered by LegalDoc.
 */
import MarketingLayout from '@/components/MarketingLayout.vue'
import LegalDoc from '@/components/LegalDoc.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { usePageMarkdown } from '@/i18n'

usePageMeta({
  title: 'Terms & Conditions — GitKittie',
  description:
    'The terms of use for the GitKittie apps, GitKittie Folder, GitKittie Kanban and GitKittie Bud — provided as-is, using your own git repositories and accounts.',
})

const body = usePageMarkdown('terms')
</script>

<template>
  <MarketingLayout>
    <LegalDoc title="Terms &amp; Conditions" updated="July 2026" :content="body" />
  </MarketingLayout>
</template>
