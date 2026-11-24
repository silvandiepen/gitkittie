<script setup lang="ts">
/**
 * @view TermsPage
 * Terms & Conditions for the GitKittie apps. Body prose lives in
 * i18n/pages/<locale>/terms.md and is rendered by LegalDoc.
 */
import MarketingLayout from '@/components/MarketingLayout.vue'
import LegalDoc from '@/components/LegalDoc.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent, usePageMarkdown } from '@/i18n'

interface LegalContent {
  privacy: { meta: { title: string; description: string } }
  terms: { meta: { title: string; description: string } }
}

const { meta } = useContent<LegalContent>('legal').terms
usePageMeta({ title: meta.title, description: meta.description })

const body = usePageMarkdown('terms')
</script>

<template>
  <MarketingLayout>
    <LegalDoc title="Terms &amp; Conditions" updated="July 2026" :content="body" />
  </MarketingLayout>
</template>
