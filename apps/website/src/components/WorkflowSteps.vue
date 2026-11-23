<script setup lang="ts">
/**
 * @component WorkflowSteps
 * A workflow as numbered steps side by side, each with the screen it happens on. Real
 * screenshots in order, so the page shows how a task is done instead of describing it.
 * Stacks on narrow screens.
 *
 * `workflow.title` is markdown: wrap the accent phrase in *…*.
 */
import { Markdown } from '@sil/ui'
import AppShot from './AppShot.vue'
import type { Workflow } from '@/lib/content'

defineProps<{ workflow: Workflow }>()

/** 1-based, zero-padded, like the feature list's markers. */
function marker(i: number): string {
  return String(i + 1).padStart(2, '0')
}
</script>

<template>
  <div class="workflow">
    <div class="mkt__section-head">
      <span class="mkt__eyebrow">{{ workflow.eyebrow }}</span>
      <div class="mkt__section-head-copy">
        <Markdown class="mkt__display-s" tag="h2" inline :content="workflow.title" />
        <p class="mkt__body">{{ workflow.subtitle }}</p>
      </div>
    </div>

    <ol class="workflow__steps" role="list">
      <li v-for="(step, i) in workflow.steps" :key="step.title" class="workflow__step">
        <AppShot
          class="workflow__shot"
          :device="step.shot.device"
          :light="step.shot.light"
          :dark="step.shot.dark"
          :alt="step.shot.alt"
          :width="step.shot.width"
          :height="step.shot.height"
        />
        <div class="workflow__copy">
          <span class="mkt__marker">{{ marker(i) }}</span>
          <h3 class="mkt__heading">{{ step.title }}</h3>
          <p class="workflow__text">{{ step.text }}</p>
        </div>
      </li>
    </ol>
  </div>
</template>

<style lang="scss">
.workflow {
  display: flex;
  flex-direction: column;
  gap: var(--space-xl);

  &__steps {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: clamp(var(--space-l), 4vw, var(--space-xl));
    padding: 0;
  }

  &__step {
    display: flex;
    flex-direction: column;
    gap: var(--space);
  }

  &__shot {
    align-self: center;
  }

  &__copy {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
  }

  &__text {
    font-size: var(--font-size-s);
    line-height: var(--line-height-relaxed);
    color: var(--color-muted);
  }
}
</style>
