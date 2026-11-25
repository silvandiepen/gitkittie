# GitKittie Mail for iPhone and iPad

The iOS and iPadOS app (GKM-027). The product docs are the Mac app's: read
`apps/gitmail-macos/AGENTS.md` and its `docs/` (Architecture.md "iOS and iPadOS", Decisions
MAIL-050..053, MAIL-067..070 and MAIL-072, ThreatModel.md) first. Follow the root `AGENTS.md`.

## Where things live

- `swift/MailAppModel` — the UI-free app model, shared with the Mac app (MAIL-067). Change it with
  both apps in mind; the Mac app's tests (`npm run gitmail:test`) cover it.
- `GitMail/App` — the entry point, the background tasks (`BGAppRefreshTask`,
  `BGProcessingTask`, `beginBackgroundTask`) and `UITestLaunch` (Debug only).
- `GitMail/Support` — UI-free iOS parts: `MobileSession` (lifecycle, background runs, MAIL-069),
  `StorageBudget` / `DeviceCache` (MAIL-068; the 30-day history window, MAIL-072), `MailFolderCheck` (Files changed the folder).
- `GitMail/Views` — SwiftUI: `RootView` (three-column split view), `MailboxesView`,
  `MessageListScreen` + `SearchChips`, `Reader/` (the safe reader: `MailReaderWeb`, link sheet),
  `Compose/` (compose, drafts, outbox), `Accounts/`, `Settings/`.
- `Tests` — hosted in the app (the Keychain test needs its entitlement); `UITests` — the flow
  against the local test server, with screenshots.

## Build and test

- Generate: `xcodegen generate` here (never hand-edit the `.xcodeproj`; it is ignored).
- Test: `zsh apps/gitmail-ios/scripts/test.sh` (iPhone 17 Pro Max simulator by default;
  `DESTINATION='platform=iOS Simulator,name=iPad Pro 13-inch (M5)'` for the iPad). Start the
  server first for the account, lifecycle and UI tests:
  `swift/GitKittieMailProviders/scripts/test-mail-server.sh start` (the simulator reaches it on
  loopback). `SCREENSHOTS=<folder>` exports the UI test's screenshots.
- CI: `.github/workflows/gitmail-ios.yml`.
- Device: build Debug or Release with automatic signing (`-allowProvisioningUpdates`, team
  `38MGF83L2L`) and `xcrun devicectl device install app --device <id> Mail.app`. Only Sil's test
  iPhone 14 Pro; never the iPhone 18 Pro.

## Rules

- Same safety as the Mac: remote content off, links through the link sheet, never send twice.
- Background work is opportunistic; never promise instant notifications in UI or copy.
- The mail folder is `Documents/Mail`, visible in Files (MAIL-051); device state stays in
  Application Support; the cache is never backed up.
