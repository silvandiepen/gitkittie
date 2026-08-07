<script setup lang="ts">
/**
 * @component ArlezSupport
 * The way to reach a person about GitKittie. Wraps Arlez's `<arlez-support>`
 * custom element, which builds its form from the project's published
 * configuration — so changing what the form asks changes here without a deploy.
 *
 * This replaces publishing an email address: a report arrives attached to the
 * product and the page it came from, and the reply comes back on the same
 * thread.
 *
 * Every origin the site is served from must be registered on the project in
 * Arlez, or launching fails with `origin_not_allowed`.
 */
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { arlezProjectId, arlezScriptUrl } from '@/links'

withDefaults(defineProps<{
  label?: string
  loadingLabel?: string
  errorLabel?: string
}>(), {
  label: 'Send a message',
  loadingLabel: 'Opening support…',
  errorLabel: 'Support could not be opened. Please try again.',
})

const element = ref<HTMLElement | null>(null)

/**
 * The SDK is fetched once per page, and only where a support control actually
 * renders — no third-party script on pages that do not offer support.
 */
function loadSdk() {
  if (document.querySelector(`script[src="${arlezScriptUrl}"]`)) return

  const script = document.createElement('script')
  script.src = arlezScriptUrl
  script.async = true
  document.head.appendChild(script)
}

/** The element reports a safe error code; surface it without leaking detail. */
function onError(event: Event) {
  const code = (event as CustomEvent<{ code?: string }>).detail?.code
  console.warn('[GitKittie] Arlez support failed to open:', code ?? 'unknown')
}

onMounted(() => {
  loadSdk()
  element.value?.addEventListener('arlez:error', onError)
})

onBeforeUnmount(() => {
  element.value?.removeEventListener('arlez:error', onError)
})
</script>

<template>
  <div class="arlez-support">
    <arlez-support
      ref="element"
      :project="arlezProjectId"
      :label="label"
      :loading-label="loadingLabel"
      :error-label="errorLabel"
      target="_blank"
    />
  </div>
</template>

<style lang="scss">
// The custom element renders its own launcher button. These are the four
// properties its appearance API exposes; the hosted form itself is themed in
// Arlez, not here.
.arlez-support {
  display: inline-flex;

  arlez-support {
    --arlez-accent: var(--color-foreground);
    --arlez-button-text: var(--color-background);
    --arlez-text: currentColor;
    --arlez-radius: var(--radius-pill);
  }
}
</style>
