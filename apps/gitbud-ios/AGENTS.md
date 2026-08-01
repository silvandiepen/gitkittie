# GitBud (iOS/iPadOS) — Agent Instructions

Read the root `../../AGENTS.md` first; this file adds GitBud-iOS-specific rules.

## What this app is

GitBud for iOS and iPadOS is planned as a remote-only native SwiftUI companion to
GitBud macOS. It uses GitPont for repository access and AIPont BYOK for Magic.

It must not depend on:

- Shelling out to `git`.
- SSH agent access.
- A full local clone as the primary data model.
- macOS-only AppKit/security-scoped-folder workflows.

## Where things live

- **Code:** `apps/gitbud-ios/GitBud/` once scaffolded.
- **Shared Swift:** `../../swift/GitKit` for provider-agnostic models that do
  not assume shell git or local checkouts.
- **App docs:** `apps/gitbud-ios/docs/{Features,Decisions,Architecture}.md`.
- **GitPont:** remote repositories, branches, file reads/writes, provider auth,
  and PR/MR workflows.
- **AIPont:** BYOK Magic suggestions.

## Platform rules

- Treat remote repositories as the source of truth.
- Prefer branch/PR workflows over destructive history rewriting.
- Do not add APIs to shared layers that make iOS pretend it has macOS shell-git
  capabilities.
- Keep provider tokens and AI keys in Keychain only.
- Do not add GitBud accounts, a hosted GitBud backend, or GitBud-owned sync
  infrastructure.
