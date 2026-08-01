# GitBud (macOS) — Agent Instructions

Read the root `../../AGENTS.md` first; this file adds GitBud-macOS-specific
rules. Global hard rules still apply: do not commit/push/deploy without an
explicit current-turn request, do not commit secrets, do not add AI co-author
trailers, and do not work around failing checks.

## What this app is

GitBud for macOS is a native SwiftUI git client focused on making history
editing simple: visual branch flow, commit graph, file history, interactive
rebase, commit splitting, squashing/merging, reordering, message rewriting, and
safe purge workflows.

Phase 1 is macOS-first and supports:

- Local repositories opened from disk.
- Remote repositories connected through GitPont and cloned into app-managed
  checkouts for full history editing.
- AIPont BYOK for AI-assisted commit titles and descriptions.

## Where things live

- **Code:** `apps/gitbud-macos/GitBud/` for app UI and state sources.
- **Testable app core:** the XcodeGen `GitBudCore` framework target compiles
  `AppModel` and settings for non-hosted unit tests.
- **Shared Swift:** `../../swift/GitKittieKit` owns git graph, diff, rewrite, safety,
  and purge primitives. GitBud UI must not launch git directly.
- **App docs:** `apps/gitbud-macos/docs/{Features,Decisions,Architecture}.md`.
- **GitPont:** provider auth, remote repo listing, branch metadata, HTTPS git
  credential context, and PR/MR workflows.
- **AIPont:** BYOK provider abstraction for Magic commit-message suggestions.

## Architecture rules

- Keep `AppModel` as the single UI-facing `@Observable` state object.
- Keep AppModel-level behavior testable through `GitBudCore`; avoid requiring a
  hosted app launch for git rewrite tests.
- Views call `AppModel` intents only; git/AIPont/GitPont operations sit behind
  UI-agnostic services.
- Shell git is allowed on macOS only through GitKittie service boundaries.
- Use argv-based process launching only; never build shell strings with user
  repo paths, branches, refs, or commit messages.
- Store persisted provider tokens and AI keys only in Keychain.
- Do not add GitBud accounts, a hosted GitBud backend, or GitBud-owned sync
  infrastructure.
- Rewrites must be protected by default: require a clean tree, create a safety
  branch/ref, preview rewritten commits, and require explicit confirmation for
  force-with-lease pushes.
- Full-history purge is a dangerous workflow, not a normal delete action. It must
  create backup refs and use explicit confirmation language.

## Platform rule

iOS and iPadOS GitBud are remote-only through GitPont. Do not design shared
GitBud workflows that require iOS/iPad to shell out to git, access an SSH agent,
or maintain a full local clone.
