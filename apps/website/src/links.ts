// Central place for external + cross-page links.

/** Canonical production origin (used for meta canonical/OG URLs + sitemap). */
export const siteOrigin = 'https://gitkittie.hakobs.com'

/**
 * GitKittie Folder — one App Store record covering macOS and iOS. The bare link lets
 * the App Store pick the right platform for the visitor; `?mt=12` forces the Mac listing.
 */
export const gitfolderAppStoreUrl = 'https://apps.apple.com/app/id6784713824'
export const gitfolderMacAppStoreUrl = `${gitfolderAppStoreUrl}?mt=12`

/** Kept for older imports; points at the GitKittie Folder Mac listing as it always did. */
export const appStoreUrl = gitfolderMacAppStoreUrl

/**
 * GitKittie Kanban — like Folder, one App Store record covering macOS and iOS
 * since the Mac build shipped at 1.0. Same `?mt=12` trick for the Mac listing.
 */
export const gitkanbanAppStoreUrl = 'https://apps.apple.com/app/id6792793088'
export const gitkanbanMacAppStoreUrl = `${gitkanbanAppStoreUrl}?mt=12`

/**
 * Arlez project for this site — `GitKittie Website · Web` in the GitKittie
 * workspace. A `pub_…` product ID routes reports to a project and is explicitly
 * not a credential, so it ships in the page. The founder `arlez_key_…` never
 * does.
 *
 * Every origin the site is served from must be registered on the project in
 * Arlez, or the support sheet fails with `origin_not_allowed`.
 */
export const arlezProjectId = 'pub_af0f09e38be86b7b39d91df6'

/** Web SDK entry point. `/v1/` takes compatible updates; pin a version to freeze it. */
export const arlezScriptUrl = 'https://cdn.arlez.app/v1/arlez.js'

// Nothing here exposes a personal email address any more. Every "notify me",
// "ask about this" and support route goes through Arlez instead, so a message
// arrives attached to the product it came from and the reply comes back on the
// same thread — see `ArlezSupport.vue`.
