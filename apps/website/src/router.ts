import { createRouter, createWebHistory } from 'vue-router'

declare module 'vue-router' {
  interface RouteMeta {
    title?: string
  }
}

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', name: 'home', component: () => import('./pages/HomePage.vue'), meta: { title: 'GitKittie — Small Mac apps built on your own git' } },
    { path: '/gitfolder', name: 'gitfolder', component: () => import('./pages/GitFolderPage.vue'), meta: { title: 'GitFolder — Automatic version history for your folders' } },
    { path: '/gitkanban', name: 'gitkanban', component: () => import('./pages/GitKanbanPage.vue'), meta: { title: 'GitKanban — Your kanban board is a git repo' } },
    { path: '/gitbud', name: 'gitbud', component: () => import('./pages/GitBudPage.vue'), meta: { title: 'GitBud — Rewriting git history, made visual' } },
    { path: '/docs', name: 'docs', component: () => import('./pages/DocsPage.vue'), meta: { title: 'Docs — GitFolder' } },
    { path: '/support', name: 'support', component: () => import('./pages/SupportPage.vue'), meta: { title: 'Support — GitKittie' } },
    { path: '/privacy', name: 'privacy', component: () => import('./pages/PrivacyPage.vue'), meta: { title: 'Privacy — GitKittie' } },
    { path: '/terms', name: 'terms', component: () => import('./pages/TermsPage.vue'), meta: { title: 'Terms & Conditions — GitKittie' } },
  ],
  scrollBehavior(_to, _from, savedPosition) {
    if (savedPosition) return savedPosition
    return { left: 0, top: 0 }
  },
})

// Baseline document title from route meta; pages may refine it via usePageMeta.
router.afterEach((to) => {
  if (to.meta.title) document.title = to.meta.title
})
