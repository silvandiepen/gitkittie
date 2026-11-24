# GitKittie Mail

In development: the app shell (GKM-009) and the mail store (GKM-005, `swift/GitKittieMailKit`) exist; no mail feature does yet. Read docs/Features.md, Architecture.md, ThreatModel.md, ProviderAccess.md, Classification.md, Decisions.md, Roadmap.md and Plan.md (the work breakdown; each step is a GKM card on the GitKittie board). docs/ThreatModel.md lists the threats and which card owns each mitigation; read it before touching rendering, parsing, credentials, sync, the outbox or deletion. docs/ProviderAccess.md covers what Gmail, Microsoft and iCloud require. Follow root AGENTS.md and project-assets/Agents conventions. Native macOS first; shared UI-independent Swift services for later iOS/iPadOS. Apps depend on packages, never each other. Mail providers are authoritative for live mail; Git is optional, never silently uploads mail, and all future Git hosting operations go through GitPont. Security, privacy and correctness outrank convenience. Use synthetic fixtures; never commit real mail or credentials. No shipped feature is implied by this proposal.

## Build and test

- Generate: `npm run gitmail:generate` (XcodeGen; never hand-edit the `.xcodeproj`).
- App model tests (no app launch): `npm run gitmail:test`.
- Mail core: `cd swift/GitKittieMailKit && swift test`.
- `GitMail/Models` is UI-free and built into `GitMailTests` too; views live in `GitMail/Views`, the shared navy `Theme` comes from `swift/GitKittieUI`.
- The MIME reading in `MailStore` is provisional (`BasicMessageParser`) until GKM-002; a library plugs in through `MessageParsing`.
- No app icon yet; add the AppIcon set and `ASSETCATALOG_COMPILER_APPICON_NAME` together.
- Compose, drafts and the outbox (GKM-013, GKM-014): `MailCompose` (GitKittieMailKit) and `MailOutbox` (GitKittieMailProviders); in the app, `GitMail/Models/Sending` (UI-free, tested in `Tests/SendingTests.swift`) and `GitMail/Views/Compose`, `GitMail/Views/Outbox`. The outbox's guarantees are proven only by `OutboxIntegrationTests` against the real test server (`scripts/test-mail-server.sh start` in GitKittieMailProviders); run them after any change to sending. Accounts reach the outbox by registering `SendingAccountSettings` in `MailSending.registry` (GKM-010).
