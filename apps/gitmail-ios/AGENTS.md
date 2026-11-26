# GitKittie Mail for iPhone and iPad

The iOS and iPadOS app (GKM-027). The product docs are the Mac app's: read
`apps/gitmail-macos/AGENTS.md` and its `docs/` (Architecture.md "iOS and iPadOS", Decisions
MAIL-050..053, MAIL-067..070, MAIL-072 and MAIL-073..080, ThreatModel.md) first. Follow the root `AGENTS.md`.

## Where things live

- `swift/MailAppModel` — the UI-free app model, shared with the Mac app (MAIL-067). Change it with
  both apps in mind; the Mac app's tests (`npm run gitmail:test`) cover it.
- `GitMail/App` — the entry point, the background tasks (`BGAppRefreshTask`,
  `BGProcessingTask`, `beginBackgroundTask`) and `UITestLaunch` (Debug only).
- `GitMail/Support` — UI-free iOS parts: `MobileSession` (lifecycle, background runs, MAIL-069),
  `StorageBudget` / `DeviceCache` (MAIL-068, MAIL-079: 14 days, attachments when opened, a 250 MB cache; the history window, MAIL-072); pausing under the budget's minimum free space is the shared `AccountSync.downloadPause`, as on the Mac, MAIL-106, `MailFolderCheck` (Files changed the folder).
- `GitMail/Views` — SwiftUI: `RootView` (three-column split view), `MailboxesView`,
  `MessageListScreen` + `SearchChips` + `ServerResultsSection` (mail found on the server, GKM-041), `Reader/` (the safe reader: `MailReaderWeb`, link sheet),
  `Compose/` (compose, drafts, outbox), `Accounts/`, `Settings/` (with `NotificationsScreen`: account, space and list levels, MAIL-085). Tapping a notification opens its conversation (`AppModel.openFromNotification`, MAIL-086; `RootView` pushes the reader).
- `Tests` — hosted in the app (the Keychain test needs its entitlement); `UITests` — the flow
  against the local test server, with screenshots. Every UI test adds its account through
  `UITests/AddAccountForm.swift`, which reads each replaced field back (GKM-086); a tapped
  notification is `UITestLaunch.notificationTapped` plus `GKM_UITEST_NOTIFICATION_SUBJECT`
  (Debug only, GKM-085).

## Build and test

- Generate: `xcodegen generate` here (never hand-edit the `.xcodeproj`; it is ignored).
- Test: `zsh apps/gitmail-ios/scripts/test.sh` (iPhone 17 Pro Max simulator by default;
  `DESTINATION='platform=iOS Simulator,name=iPad Pro 13-inch (M5)'` for the iPad). Start the
  server first for the account, lifecycle and UI tests:
  `swift/GitKittieMailProviders/scripts/test-mail-server.sh start` (the simulator reaches it on
  loopback). `SCREENSHOTS=<folder>` exports the UI test's screenshots.
- CI: `.github/workflows/gitmail-ios.yml`.
- Accessibility (GKM-061, MAIL-089..091): `MailFlowUITests` runs `performAccessibilityAudit` on every main screen, at the default size and at Accessibility XXXL (`testMainScreensAtLargestTextSize`), and fails with the full list. Skips live only in `UITests/AccessibilityAuditPolicy.swift`, each with its reason. At the accessibility sizes rows stack their date under the sender and lift one-line limits (`dynamicTypeSize.isAccessibilitySize`); text uses `Theme.accentText`, white text sits on `Theme.accentFill`.
- Device: build Debug or Release with automatic signing (`-allowProvisioningUpdates`, team
  `38MGF83L2L`) and `xcrun devicectl device install app --device <id> Mail.app`. Only Sil's test
  iPhone 14 Pro; never the iPhone 18 Pro.

## Rules

- Same safety as the Mac: remote content off, links through the link sheet, never send twice.
- Background work is opportunistic; never promise instant notifications in UI or copy.
- The mail folder is `Documents/Mail`, visible in Files (MAIL-051); device state stays in
  Application Support; the cache is never backed up.
