# GitKittie Mail

In development: the app shell (GKM-009), the mail store (GKM-005, `swift/GitKittieMailKit`), account setup (GKM-010) and sync (GKM-011) exist. Read docs/Features.md, Architecture.md, ThreatModel.md, ProviderAccess.md, Classification.md, Decisions.md, Roadmap.md and Plan.md (the work breakdown; each step is a GKM card on the GitKittie board). docs/ThreatModel.md lists the threats and which card owns each mitigation; read it before touching rendering, parsing, credentials, sync, the outbox or deletion. docs/ProviderAccess.md covers what Gmail, Microsoft and iCloud require. Follow root AGENTS.md and project-assets/Agents conventions. Native macOS first; shared UI-independent Swift services for later iOS/iPadOS. Apps depend on packages, never each other. Mail providers are authoritative for live mail; Git is optional, never silently uploads mail, and all future Git hosting operations go through GitPont. Security, privacy and correctness outrank convenience. Use synthetic fixtures; never commit real mail or credentials. No shipped feature is implied by this proposal.

## Build and test

- Generate: `npm run gitmail:generate` (XcodeGen; never hand-edit the `.xcodeproj`).
- App model tests (no app launch): `npm run gitmail:test`.
- Mail core: `cd swift/GitKittieMailKit && swift test`.
- `GitMail/Models` is UI-free and built into `GitMailTests` too; views live in `GitMail/Views`, the shared navy `Theme` comes from `swift/GitKittieUI`.
- The MIME reading in `MailStore` is provisional (`BasicMessageParser`) until GKM-002; a library plugs in through `MessageParsing`.
- App icon: `GitMail/Assets.xcassets/AppIcon.appiconset`, rendered from project-assets `GitKittie/assets/icon_gitmail.svg`.
- Accounts and sync (GKM-010, GKM-011): `MailAccounts` (presets, verification, Keychain) and `MailSync` (the sync coordinator) in GitKittieMailProviders; sync state (folders, cursors, flags) in `sync.sqlite` via `MailStore+Sync.swift`. In the app, `GitMail/Models/AccountSync.swift`, `AppModel+Accounts.swift`, `AccountDraft.swift`, `MailFolderLocation.swift` (tested in `Tests/AccountTests.swift`) and `GitMail/Views/Accounts`. The account tests use the local test server when it runs (`GKM_TEST_MAIL_SERVER_DIR` is passed through by `scripts/test.sh`) and skip otherwise. Decisions MAIL-026..029.
