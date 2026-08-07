<script setup lang="ts">
/**
 * @view DocsPage
 * Documentation for all three GitKittie apps, with a product switcher and
 * sticky section navigation.
 *
 * All copy lives in `i18n/locales/<locale>/docs.json` so it can be translated,
 * and every prose value is markdown rendered through @sil/ui's Markdown — the
 * content files carry no HTML.
 */
import { computed, ref } from 'vue'
import { Markdown } from '@sil/ui'
import MarketingLayout from '@/components/MarketingLayout.vue'
import { usePageMeta } from '@/lib/usePageMeta'
import { useContent } from '@/i18n'

interface StepItem {
  title: string
  md: string
}

interface SpecItem {
  term: string
  md: string
}

interface FaqItem {
  q: string
  md: string
}

interface StepsBlock {
  type: 'steps'
  items: StepItem[]
}

interface ProseBlock {
  type: 'prose'
  md: string
}

interface ListBlock {
  type: 'list'
  items: string[]
}

interface CalloutBlock {
  type: 'callout'
  variant: 'info' | 'warning'
  icon: string
  title: string
  md: string
}

interface SpecsBlock {
  type: 'specs'
  items: SpecItem[]
}

interface FaqBlock {
  type: 'faq'
  items: FaqItem[]
}

type DocsBlock =
  | StepsBlock
  | ProseBlock
  | ListBlock
  | CalloutBlock
  | SpecsBlock
  | FaqBlock

interface DocsSection {
  id: string
  label: string
  title: string
  blocks: DocsBlock[]
}

interface DocsProduct {
  id: string
  /** Short label for the switcher — the full name is too long for a tab. */
  label: string
  name: string
  sections: DocsSection[]
}

interface DocsContent {
  meta: { title: string; description: string }
  sidebarNote: string
  products: DocsProduct[]
}

const t = useContent<DocsContent>('docs')

usePageMeta({
  title: t.meta.title,
  description: t.meta.description,
})

/**
 * Docs cover all three products. The switcher changes both the sections shown
 * and `[data-app]`, so the page takes on that product's hue as you move between
 * them — the same signal the product pages use.
 */
const activeProduct = ref(t.products[0]?.id ?? '')

const product = computed<DocsProduct>(
  () => t.products.find((p) => p.id === activeProduct.value) ?? t.products[0],
)

const activeSection = ref(product.value?.sections[0]?.id ?? '')

function selectProduct(id: string) {
  activeProduct.value = id
  activeSection.value = product.value?.sections[0]?.id ?? ''
  window.scrollTo({ top: 0, behavior: 'smooth' })
}

function scrollTo(id: string) {
  activeSection.value = id
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

/** 1-based, zero-padded — matches the mono markers used across the site. */
function marker(i: number): string {
  return String(i + 1).padStart(2, '0')
}
</script>

<template>
  <MarketingLayout>
    <div class="docs" :data-app="activeProduct">
      <div class="mkt__container docs__layout">
        <!-- Section navigation -->
        <aside class="docs__sidebar">
          <nav class="docs__products" aria-label="Choose a product">
            <button
              v-for="p in t.products"
              :key="p.id"
              class="docs__product"
              :class="{ 'docs__product--active': activeProduct === p.id }"
              :data-app="p.id"
              @click="selectProduct(p.id)"
            >
              {{ p.label }}
            </button>
          </nav>

          <span class="mkt__eyebrow">{{ product.name }}</span>

          <nav class="docs__nav" aria-label="Sections">
            <button
              v-for="(s, i) in product.sections"
              :key="s.id"
              class="docs__nav-link"
              :class="{ 'docs__nav-link--active': activeSection === s.id }"
              @click="scrollTo(s.id)"
            >
              <span class="mkt__marker">{{ marker(i) }}</span>
              <span class="docs__nav-label">{{ s.label }}</span>
            </button>
          </nav>

          <Markdown class="docs__note" tag="p" inline :content="t.sidebarNote" />
        </aside>

        <!-- Content -->
        <div class="docs__content">
          <section
            v-for="section in product.sections"
            :id="section.id"
            :key="section.id"
            class="docs__section"
          >
            <h2 class="docs__section-title">{{ section.title }}</h2>

            <template v-for="(block, i) in section.blocks" :key="i">
              <!-- Steps -->
              <ol v-if="block.type === 'steps'" class="mkt__rows" role="list">
                <li v-for="(step, si) in block.items" :key="si" class="mkt__row">
                  <span class="mkt__marker">{{ marker(si) }}</span>
                  <div class="mkt__row-body">
                    <h3 class="docs__item-title">{{ step.title }}</h3>
                    <Markdown class="docs__prose" tag="div" :content="step.md" />
                  </div>
                </li>
              </ol>

              <!-- Prose -->
              <Markdown
                v-else-if="block.type === 'prose'"
                class="docs__prose"
                tag="div"
                :content="block.md"
              />

              <!-- List -->
              <ul v-else-if="block.type === 'list'" class="docs__list">
                <li v-for="(item, li) in block.items" :key="li" class="docs__list-item">
                  <Markdown class="docs__prose" tag="span" inline :content="item" />
                </li>
              </ul>

              <!-- Specs -->
              <dl v-else-if="block.type === 'specs'" class="docs__specs">
                <div v-for="(spec, spi) in block.items" :key="spi" class="docs__spec">
                  <dt class="docs__spec-term">{{ spec.term }}</dt>
                  <dd class="docs__spec-value">
                    <Markdown class="docs__prose" tag="span" inline :content="spec.md" />
                  </dd>
                </div>
              </dl>

              <!-- Callout -->
              <aside
                v-else-if="block.type === 'callout'"
                class="docs__callout"
                :class="`docs__callout--${block.variant}`"
              >
                <span class="docs__callout-icon" aria-hidden="true">{{ block.icon }}</span>
                <div class="docs__callout-body">
                  <h3 class="docs__item-title">{{ block.title }}</h3>
                  <Markdown class="docs__prose" tag="div" :content="block.md" />
                </div>
              </aside>

              <!-- FAQ -->
              <div v-else-if="block.type === 'faq'" class="mkt__rows">
                <div v-for="(item, fi) in block.items" :key="fi" class="mkt__row">
                  <h3 class="docs__item-title">{{ item.q }}</h3>
                  <div class="mkt__row-body">
                    <Markdown class="docs__prose" tag="div" :content="item.md" />
                  </div>
                </div>
              </div>
            </template>
          </section>
        </div>
      </div>
    </div>
  </MarketingLayout>
</template>

<style lang="scss">
.docs {
  @include e(layout) {
    display: grid;
    grid-template-columns: 240px minmax(0, 1fr);
    gap: var(--space-xl);
    padding-top: var(--space-xl);
    padding-bottom: var(--space-xxl);

    @include tablet { grid-template-columns: 1fr; }
  }

  // ── Section navigation ─────────────────────────────────────────────────
  @include e(sidebar) {
    position: sticky;
    top: 100px;
    align-self: start;
    display: flex;
    flex-direction: column;
    gap: var(--space-l);

    @include tablet {
      position: static;
      gap: var(--space);
    }
  }

  // Product switcher: each tab wears its own product colour when selected, so
  // choosing one is the same gesture as the [data-app] hue elsewhere.
  @include e(products) {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-xs);
  }

  @include e(product) {
    padding: var(--space-xs) var(--space-s);
    border: var(--border-width) solid var(--color-border);
    border-radius: var(--radius-pill);
    font-size: var(--font-size-s);
    font-weight: var(--font-weight-semibold);
    color: color-mix(in srgb, var(--color-foreground) 70%, transparent);
    background: transparent;
    cursor: pointer;
    transition: background-color var(--transition-fast), color var(--transition-fast), border-color var(--transition-fast);

    &:hover { color: var(--color-foreground); }

    @include m(active) {
      background: var(--color-accent);
      border-color: var(--color-accent);
      color: var(--color-accent-contrast);
    }
  }

  @include e(nav) {
    display: flex;
    flex-direction: column;
  }

  // A ruled index rather than a stack of pills — the accent marks the current
  // section on its edge instead of filling a background behind it.
  @include e(nav-link) {
    display: flex;
    align-items: baseline;
    gap: var(--space-s);
    width: 100%;
    padding: var(--space-s) 0 var(--space-s) var(--space-s);
    border-top: var(--border-width) solid var(--color-border);
    border-left: 2px solid transparent;
    text-align: left;
    font-size: var(--font-size-s);
    color: color-mix(in srgb, var(--color-foreground) 70%, transparent);
    background: transparent;
    cursor: pointer;
    transition: color var(--transition-fast), border-color var(--transition-fast);

    &:hover { color: var(--color-foreground); }

    @include m(active) {
      color: var(--color-foreground);
      border-left-color: var(--color-accent);
      font-weight: var(--font-weight-semibold);
    }
  }

  @include e(note) {
    font-size: var(--font-size-xs);
    line-height: var(--line-height-relaxed);
    color: color-mix(in srgb, var(--color-foreground) 60%, transparent);
  }

  // ── Content ────────────────────────────────────────────────────────────
  @include e(content) {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-xxl);
  }

  @include e(section) {
    display: flex;
    flex-direction: column;
    gap: var(--space-l);
    scroll-margin-top: 100px;
  }

  @include e(section-title) {
    font-size: var(--font-size-display-s);
    font-weight: var(--font-weight-semibold);
    letter-spacing: var(--tracking-display);
    line-height: 1;
  }

  @include e(item-title) {
    font-size: var(--font-size-m);
    font-weight: var(--font-weight-semibold);
    letter-spacing: var(--tracking-heading);
  }

  // Rendered markdown: the one place bare element selectors are unavoidable,
  // because the elements come from the renderer, not from this template.
  @include e(prose) {
    font-size: var(--font-size-s);
    line-height: var(--line-height-relaxed);
    color: color-mix(in srgb, var(--color-foreground) 78%, transparent);

    p + p { margin-top: var(--space-s); }

    code {
      padding: 0 var(--space-xs);
      background: var(--surface-raised);
      border: var(--border-width) solid var(--color-border-light);
      font-family: var(--font-family-monospace);
      font-size: var(--font-size-xs);
    }

    a {
      color: var(--accent-legible);
      text-decoration: underline;
      text-underline-offset: 2px;
    }

    ul {
      display: flex;
      flex-direction: column;
      gap: var(--space-s);
      padding-left: var(--space);
    }

    li { list-style: disc; }
  }

  @include e(list) {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
    padding-left: var(--space);
  }

  @include e(list-item) {
    list-style: disc;
  }

  // ── Specs ──────────────────────────────────────────────────────────────
  @include e(specs) {
    display: flex;
    flex-direction: column;
  }

  @include e(spec) {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 2fr);
    gap: var(--space);
    padding: var(--space-s) 0;
    border-top: var(--border-width) solid var(--color-border);

    @include mobile { grid-template-columns: 1fr; gap: var(--space-xs); }
  }

  @include e(spec-term) {
    font-size: var(--font-size-s);
    font-weight: var(--font-weight-semibold);
  }

  @include e(spec-value) {
    margin: 0;
  }

  // ── Callout ────────────────────────────────────────────────────────────
  // Flat, square, and marked by a coloured edge rather than a rounded tinted
  // card — it has to read as an interruption, not as another content box.
  @include e(callout) {
    display: flex;
    gap: var(--space);
    padding: var(--space) var(--space-l);
    border-left: 3px solid var(--color-accent);
    background: var(--color-accent-tint);

    @include m(warning) {
      border-left-color: var(--color-warning);
      background: var(--color-warning-tint);
    }
  }

  @include e(callout-icon) {
    flex-shrink: 0;
    font-size: var(--font-size-l);
    line-height: 1.2;
  }

  @include e(callout-body) {
    display: flex;
    flex-direction: column;
    gap: var(--space-xs);
  }
}
</style>
