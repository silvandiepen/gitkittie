<script setup lang="ts">
/**
 * @component MarketingLayout
 * Shared layout for all GitKittie marketing pages. Neutral umbrella shell (header +
 * footer); product pages set their own [data-app] on the page root to theme
 * content. Uses @sil/ui PillHeader and the GitKittie mark.
 */
import { computed, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { PillHeader } from '@sil/ui'
import type { PillHeaderAction, PillHeaderNavItem } from '@sil/ui'
import GitKittieMark from './GitKittieMark.vue'
import { useContent } from '@/i18n'

/** A nav entry is either a link or a parent that only opens a submenu. */
interface NavLink {
  label: string
  to?: string
  description?: string
  items?: NavLink[]
}
interface FooterLink { label: string; to?: string; href?: string; external?: boolean }
interface FooterColumn { heading: string; links: FooterLink[] }
interface CommonContent {
  brand: { name: string; tagline: string }
  nav: NavLink[]
  skipToContent: string
  actions: { toLight: string; toDark: string }
  footer: { columns: FooterColumn[]; copy: string }
}

const t = useContent<CommonContent>('common')

const route = useRoute()
const isDark = ref(true)

/**
 * `exact` only makes sense on entries that actually link somewhere — a parent
 * like "Apps" has no `to`, and PillHeader marks it active from its children.
 */
function toNavItem(n: NavLink): PillHeaderNavItem {
  return {
    label: n.label,
    ...(n.to ? { to: n.to, exact: true } : {}),
    ...(n.description ? { description: n.description } : {}),
    ...(n.items ? { items: n.items.map(toNavItem) } : {}),
  }
}

const navItems = computed<PillHeaderNavItem[]>(() => t.nav.map(toNavItem))

const actions = computed<PillHeaderAction[]>(() => [
  {
    label: isDark.value ? t.actions.toLight : t.actions.toDark,
    icon: isDark.value ? 'weather/sun-light-mode' : 'weather/moon-dark-mode',
    iconOnly: true,
    handler: toggleColorMode,
  },
])

function applyMode(mode: 'dark' | 'light') {
  // @sil/ui colour tokens key off [data-theme]; the pre-paint script also sets
  // [data-color-mode]. Keep both in sync.
  document.documentElement.setAttribute('data-color-mode', mode)
  document.documentElement.setAttribute('data-theme', mode)
}

function toggleColorMode() {
  isDark.value = !isDark.value
  const mode = isDark.value ? 'dark' : 'light'
  applyMode(mode)
  localStorage.setItem('gitkittie-color-mode', mode)
}

onMounted(() => {
  const storedMode = localStorage.getItem('gitkittie-color-mode')
  const currentMode = (storedMode || document.documentElement.getAttribute('data-color-mode') || 'dark') as 'dark' | 'light'
  isDark.value = currentMode === 'dark'
  applyMode(currentMode)
})

const year = new Date().getFullYear()
</script>

<template>
  <div class="mlayout">
    <a href="#main" class="skip-link">{{ t.skipToContent }}</a>

    <PillHeader
      :nav-items="navItems"
      :actions="actions"
      :current-path="route.path"
      brand-to="/"
      :brand-suffix="t.brand.name"
      :brand-aria-label="`${t.brand.name} — Home`"
      color-mode="auto"
      menu-icon="ui/menu"
      close-icon="ui/multiply-m"
      class="mlayout__pill-header"
    >
      <template #brand-mark>
        <GitKittieMark class="mlayout__brand-mark" :size="24" :title="t.brand.name" />
      </template>
    </PillHeader>

    <main id="main" class="mlayout__main">
      <slot />
    </main>

    <footer class="mlayout__footer">
      <div class="mkt__container mlayout__footer-inner">
        <div class="mlayout__footer-brand-col">
          <router-link to="/" class="mlayout__footer-brand">
            <GitKittieMark class="mlayout__footer-mark" :size="20" :title="t.brand.name" />
            <span>{{ t.brand.name }}</span>
          </router-link>
          <p class="mlayout__footer-tagline">{{ t.brand.tagline }}</p>
        </div>

        <nav class="mlayout__footer-cols" aria-label="Footer">
          <div v-for="col in t.footer.columns" :key="col.heading" class="mlayout__footer-col">
            <h2 class="mkt__eyebrow">{{ col.heading }}</h2>
            <template v-for="l in col.links" :key="l.label">
              <a v-if="l.external" class="mlayout__footer-link" :href="l.href" target="_blank" rel="noopener">{{ l.label }}</a>
              <router-link v-else class="mlayout__footer-link" :to="l.to!">{{ l.label }}</router-link>
            </template>
          </div>
        </nav>
      </div>

      <div class="mkt__container mlayout__footer-base">
        <p class="mlayout__footer-copy">&copy; {{ year }} {{ t.footer.copy }}</p>
      </div>
    </footer>
  </div>
</template>

<style lang="scss">
.mlayout {
  min-height: 100vh;
  background: var(--color-background);
  display: flex;
  flex-direction: column;

  &__pill-header {
    --pill-header-position: fixed;
    --pill-header-padding: 14px clamp(16px, 4vw, 32px) 0;
    --pill-header-radius: 999px;
    --pill-header-brand-gap: 10px;
    color: var(--color-foreground);
  }

  &__brand-mark,
  &__footer-mark {
    color: currentColor;
    flex: 0 0 auto;
  }

  &__main {
    flex: 1;
    padding-top: 76px;
  }

  // ── Footer ─────────────────────────────────────────────────────────────
  // Ink, like the closing band it sits under, so the page ends in one dark
  // block rather than a grey strip below a dark one.
  &__footer {
    padding: var(--space-xl) 0 var(--space-l);
    margin-top: auto;
    background: var(--color-dark);
    color: var(--color-light);
  }

  &__footer-inner {
    display: grid;
    grid-template-columns: minmax(0, 1.4fr) minmax(0, 2fr);
    gap: var(--space-xl);
    padding-bottom: var(--space-xl);

    @include tablet { grid-template-columns: 1fr; gap: var(--space-l); }
  }

  &__footer-brand-col {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
  }

  &__footer-brand {
    display: inline-flex;
    align-items: center;
    gap: var(--space-s);
    text-decoration: none;
    font-weight: var(--font-weight-semibold);
    font-size: var(--font-size-m);
    letter-spacing: var(--tracking-eyebrow);
    text-transform: uppercase;
    color: var(--color-light);

    &:hover { color: var(--color-light); }
  }

  &__footer-tagline {
    font-size: var(--font-size-s);
    line-height: var(--line-height-relaxed);
    max-width: 32ch;
    color: color-mix(in srgb, var(--color-light) 70%, transparent);
  }

  &__footer-cols {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: var(--space-l);

    @include mobile { grid-template-columns: repeat(2, 1fr); }
  }

  &__footer-col {
    display: flex;
    flex-direction: column;
    gap: var(--space-s);
  }

  &__footer-link {
    width: fit-content;
    font-size: var(--font-size-s);
    text-decoration: none;
    color: color-mix(in srgb, var(--color-light) 72%, transparent);
    transition: color var(--transition-fast);

    &:hover { color: var(--color-light); }
  }

  &__footer-base {
    padding-top: var(--space-l);
    border-top: var(--border-width) solid color-mix(in srgb, var(--color-light) 20%, transparent);
  }

  &__footer-copy {
    font-size: var(--font-size-xs);
    color: color-mix(in srgb, var(--color-light) 55%, transparent);
  }
}

.pill-header__action--icon-only .pill-header__action-label,
.pill-header__action[aria-label*="Switch"] .pill-header__action-label {
  display: none;
}

// The Apps submenu — two @sil/ui defaults don't suit a menu with descriptions.
.pill-header__submenu {
  // The shell background is glassy by design for the header pill itself, but a
  // panel that overlaps the hero has to be opaque to stay readable.
  background: var(--surface);
  backdrop-filter: none;

  // Only the floating desktop panel needs the extra width; below @sil/ui's
  // 768px breakpoint the submenu is inline in the drawer and 20rem overflows it.
  @media (min-width: 768px) {
    min-width: 20rem;
  }
}

.pill-header__submenu-description {
  // Defaults to nowrap + ellipsis, which truncates every product description.
  white-space: normal;
  overflow: visible;
  line-height: var(--line-height-normal);
  color: var(--color-muted);
}

@media (max-width: 720px) {
  .mlayout__main {
    padding-top: 84px;
  }
}
</style>
