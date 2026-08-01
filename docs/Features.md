# GitKit — Features (monorepo overview)

This is the **monorepo-level** capability map for GitKit. It describes what GitKit is,
the products it houses, and the shared engine underneath them. Per-app detail lives in
each app's own `docs/Features.md` (linked below); GitFolder's full product plans live in
this repo's `docs/*.md` (product-spec, data-model, sync-model, etc.).

## What GitKit is

GitKit is **a monorepo for git-backed apps** — apps that make a git repository a quiet,
first-class backend for everyday work, rather than a tool you consciously operate. Three
products share one git foundation, so the plumbing lives once in this repo and the apps depend
on it.

The common thesis across every app:

- **Local-first / remote-provider-first.** macOS apps use real local git clones where full git
  semantics matter. iOS/iPadOS apps can be remote-provider-first through GitPont when the platform
  should not depend on shell git or full local clones.
- **Own-your-data.** The source of truth is plain files (folders, or markdown cards) in a
  repository the user owns and hosts wherever they host git. No proprietary store, no export
  step — the data is already portable.
- **No-server.** There is no GitKit or GitBud backend. The apps talk directly to the user's git
  host over the user's own credentials. Nothing is relayed through infrastructure we run. History,
  offline access where supported, and portability come from git itself.

Concretely, "no-server" means: provider credentials live in the OS Keychain; every change is a
commit; the only network calls are git transport, hosted git provider APIs, and user-selected
AI provider APIs, made as the user.

## The products

| Product | What it is | Data shape |
|---|---|---|
| **GitFolder** | A macOS menu-bar app that auto-versions selected folders to GitHub — quiet snapshot commits on an interval when files change. Background sync utility. | Arbitrary folders → git history |
| **GitKanban** | A native kanban board backed by a git repo of markdown files — every card is a file, every card move is a commit. Foreground editor. | Markdown cards + board config → git history |
| **GitBud** | A native git client focused on simple visual history editing: branch flow, file history, rebase, split, squash, reorder, Magic messages, and purge. | Repositories + commits + diffs → rewritten history |

The products are complementary: GitFolder syncs any folder in the background; GitKanban is a
foreground editor for a specific folder shape (a board of markdown cards); GitBud is a foreground
git client for understanding and repairing history.

## Apps × platform × status

| App | Location | Platform / stack | Status |
|---|---|---|---|
| GitFolder (macOS) | `apps/gitfolder-macos/` | SwiftUI + AppKit menu-bar app, XcodeGen | **Shipping** (App Store) |
| GitFolder (iOS) | `apps/gitfolder-ios/` | SwiftUI, embedded libgit2 (planned) | Planned — docs/spec only; libgit2 spike outstanding |
| GitKanban (macOS) | `apps/gitkanban-macos/` | SwiftUI board app, XcodeGen | In development — read-only board UI (loads markdown boards via GitKit; editing/drag/git-sync deferred) |
| GitKanban (iOS) | `apps/gitkanban-ios/` | SwiftUI, libgit2 (planned) | Planned — Phase 2, not scaffolded |
| GitBud (macOS) | `apps/gitbud-macos/` | SwiftUI git client, XcodeGen | In development — local repo graph/diff/history, rewrite actions, conflicts, Magic BYOK, purge, force-with-lease |
| GitBud (iOS/iPadOS) | `apps/gitbud-ios/` | SwiftUI remote git client, XcodeGen planned | Planned — docs/spec only; GitPont remote-only |
| Website | `apps/website/` | Vue 3 + Vite, deployed on Cloudflare Pages | Shipping |

> Status is deliberately honest. Only GitFolder macOS ships today. GitKanban macOS is in
> development — it builds and renders a read-only board loaded via GitKit, with editing,
> drag-to-move, and git-sync still deferred. GitBud macOS now has a tested native scaffold for
> local history inspection and rewrite workflows, while GitBud iOS/iPadOS remains plan-only.
> The shared Swift package extraction (see below) is **in progress**, not complete.

## The shared engine

The native apps depend on shared Swift packages, especially **`swift/GitKit`**, so common git,
auth, parsing, and app-service behavior can live once:

- **`GitEngine`** — the single protocol that knows git (`clone / pullRebase / commit / push /
  status / fileHistory`). The apps call only this, so the same UI runs over different git
  backends. Two implementations:
  - `ShellGitEngine` — macOS, shells out to the `git` binary (ported from GitFolder's
    `GitRunner`). **Implemented, tested.**
  - `Libgit2Engine` — iOS, embedded libgit2 over HTTPS (iOS has no shell / no subprocess).
    **Pending** — the highest-risk unknown for iOS.
- **`KeychainService`** — generic Keychain item store. Implemented.
- **`GitHubOAuthService`** — GitHub device-flow OAuth, Foundation-only (macOS + iOS). Implemented.
- **Pending extraction** from `apps/gitfolder-macos`: `FolderAccessService` (security-scoped
  bookmarks), `ConfigStore` (per-app model), `MarkdownStore` (files ⇄ cards). These still live
  in GitFolder and are being moved out as each move can be Xcode-verified.
- **`ShellGitHistoryService`** — GitBud's tested local history/rewrite layer: commit graph,
  changed files, diffs, safety branches, split by file/hunk, squash, drop, reorder, conflicts,
  purge, and force-with-lease.
- **`AIPontMagicService`** — direct BYOK AI request layer for GitBud Magic commit messages
  across OpenAI-compatible, Anthropic, and Gemini-style providers.

The board **schema and logic** are not in Swift — they live in TypeScript (`packages/gitkanban-core`)
as the source of truth, and Swift mirrors them. See `docs/Architecture.md`.

## Per-app feature docs

For product-level capabilities, see each app's own docs:

- GitFolder (macOS): `apps/gitfolder-macos/docs/Features.md` + this repo's `docs/product-spec.md`,
  `docs/data-model.md`, `docs/sync-model.md`, `docs/github-access.md`, `docs/macos-permissions.md`.
- GitFolder (iOS): `apps/gitfolder-ios/docs/Features.md`.
- GitKanban (macOS): `apps/gitkanban-macos/README.md`; board contract in
  `packages/gitkanban-core/README.md`; full plan in `project-assets` `GitKit/GitKanban/plan/`.
- GitBud (macOS): `apps/gitbud-macos/docs/Features.md`, `apps/gitbud-macos/docs/Architecture.md`,
  `apps/gitbud-macos/docs/Decisions.md`.
- GitBud (iOS/iPadOS): `apps/gitbud-ios/docs/Features.md`,
  `apps/gitbud-ios/docs/Architecture.md`, `apps/gitbud-ios/docs/Decisions.md`.
- Website: `apps/website/`.
