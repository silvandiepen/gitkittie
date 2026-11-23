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
    { path: '/folder', name: 'folder', component: () => import('./pages/FolderPage.vue'), meta: { title: 'GitKittie Folder — Automatic version history for your folders' } },
    { path: '/tasks', name: 'tasks', component: () => import('./pages/TasksPage.vue'), meta: { title: 'GitKittie Tasks — Your task board is a git repo' } },
    { path: '/bud', name: 'bud', component: () => import('./pages/BudPage.vue'), meta: { title: 'GitKittie Bud — Rewriting git history, made visual' } },
    // The product pages were at /gitfolder, /gitkanban and /gitbud before the apps were
    // named GitKittie Folder, Tasks and Bud. public/_redirects sends those with a 301 on
    // Cloudflare; these catch a link followed inside the app or in `vite dev`.
    { path: '/gitfolder', redirect: '/folder' },
    { path: '/gitkanban', redirect: '/tasks' },
    { path: '/gitbud', redirect: '/bud' },
    { path: '/blog', name: 'blog', component: () => import('./pages/BlogIndexPage.vue'), meta: { title: 'Writing — GitKittie' } },
    { path: '/blog/:slug', name: 'blog-post', component: () => import('./pages/BlogPostPage.vue'), meta: { title: 'Writing — GitKittie' } },
    { path: '/docs', name: 'docs', component: () => import('./pages/DocsPage.vue'), meta: { title: 'Docs — GitKittie' } },
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
