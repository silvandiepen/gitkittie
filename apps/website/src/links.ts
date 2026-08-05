// Central place for external + cross-page links.

/** Canonical production origin (used for meta canonical/OG URLs + sitemap). */
export const siteOrigin = 'https://gitkit.app'

/**
 * GitFolder — one App Store record covering macOS and iOS. The bare link lets the
 * App Store pick the right platform for the visitor; `?mt=12` forces the Mac listing.
 */
export const gitfolderAppStoreUrl = 'https://apps.apple.com/app/id6784713824'
export const gitfolderMacAppStoreUrl = `${gitfolderAppStoreUrl}?mt=12`

/** Kept for older imports; points at the GitFolder Mac listing as it always did. */
export const appStoreUrl = gitfolderMacAppStoreUrl

/** GitKit Kanban — iPhone and iPad only for now; no Mac build exists yet. */
export const gitkanbanAppStoreUrl = 'https://apps.apple.com/app/id6792793088'

/** Shared GitHub repository for the GitKit family. */
export const githubRepoUrl = 'https://github.com/silvandiepen/Gitfolder'

/** GitKanban for Mac is still in development — "notify me" stays a static mailto. */
export const gitkanbanMacNotify =
  'mailto:me@sil.mt?subject=Notify%20me%20about%20GitKanban%20for%20Mac&body=Let%20me%20know%20when%20GitKanban%20for%20Mac%20is%20available.'

/** Support contact. */
export const supportEmail = 'me@sil.mt'
export const supportMailto = 'mailto:me@sil.mt?subject=GitKit%20support'
