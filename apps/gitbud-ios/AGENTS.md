# GitKittie Bud (iOS/iPadOS) — Agent Instructions

Read the root `../../AGENTS.md` first; this file adds GitBud-iOS-specific rules.

## What this app is

GitKittie Bud for iOS and iPadOS is a remote-only native SwiftUI companion to GitKittie Bud
macOS. It uses GitPont for repository access and Apple's on-device model (through AIPont) for
Magic. Run the demo with `GITBUD_DEMO=1`; `GITBUD_COMMIT`, `GITBUD_FILE` and `GITBUD_DIFF_MODE`
open a commit, a file and a view for screenshots and UI tests.

It must not depend on:

- Shelling out to `git`.
- SSH agent access.
- A full local clone as the primary data model.
- macOS-only AppKit/security-scoped-folder workflows.

## Where things live

- **Code:** `apps/gitbud-ios/GitBud/` (App, Services, Views); tests in `Tests/` and `UITests/`.
- **Build/test:** `xcodegen generate`, then `xcodebuild test -project GitBud.xcodeproj -scheme GitBud -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' CODE_SIGNING_ALLOWED=NO`.
- **Shared Swift:** `../../swift/GitKittieKit` for provider-agnostic models that do
  not assume shell git or local checkouts.
- **App docs:** `apps/gitbud-ios/docs/{Features,Decisions,Architecture}.md`.
- **GitPont:** remote repositories, branches, file reads/writes, provider auth,
  and PR/MR workflows.
- **AIPont:** Magic, on-device first (Decision 5).

## Platform rules

- Treat remote repositories as the source of truth.
- Prefer branch/PR workflows over destructive history rewriting.
- Do not add APIs to shared layers that make iOS pretend it has macOS shell-git
  capabilities.
- Keep provider tokens and AI keys in Keychain only.
- Do not add GitKittie Bud accounts, a hosted GitKittie Bud backend, or GitKittie Bud-owned sync
  infrastructure.
