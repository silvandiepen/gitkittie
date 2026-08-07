<script setup lang="ts">
/**
 * @view PrivacyPage
 * Unified privacy policy for the GitKittie apps. Body prose lives in
 * i18n/pages/<locale>/privacy.md and is rendered by LegalDoc.
 */
import MarketingLayout from '@/components/MarketingLayout.vue'
import LegalDoc from '@/components/LegalDoc.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { usePageMarkdown } from '@/i18n'

usePageMeta({
  title: 'Privacy — GitKittie',
  description:
    'GitKittie apps are local-first: no accounts, no cloud service, no telemetry. Your files move directly between your Mac and the git host you own.',
})

const body = usePageMarkdown('privacy')
</script>

<template>
  <MarketingLayout>
    <LegalDoc title="Privacy Policy" updated="July 2026" :content="body" />
  </MarketingLayout>
</template>
