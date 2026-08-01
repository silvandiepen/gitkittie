# GitKittie

**A monorepo for git-backed apps.** GitKittie houses the apps that make git a quiet,
first-class backend for everyday work — and the shared engine they run on.

| App | What it is | Status |
|---|---|---|
| **GitFolder** | macOS menu-bar app that auto-versions selected folders to GitHub | Shipping (App Store) |
| **GitKanban** | macOS/iOS kanban board backed by a git repo of markdown files | In development |
| **GitBud** | macOS/iOS/iPadOS git client focused on visual history editing and simple rebasing | macOS scaffold in development |

The products are local-first or remote-provider-first depending on platform, own-your-data,
no-server apps that treat a git repository as the source of truth. They share the same git
plumbing, so it lives in one repo.

## Repository layout

```txt
apps/
  gitfolder-macos/    GitFolder — macOS menu-bar app (SwiftUI/AppKit, XcodeGen)
  gitkanban-macos/    GitKanban — macOS board app (read-only board UI)
  gitbud-macos/       GitBud — macOS git client (SwiftUI/AppKit, XcodeGen)
  gitbud-ios/         GitBud — iOS/iPadOS remote git client (planned; docs/spec only)
  website/            Marketing/docs site (Vue 3 + Vite)
packages/
  core/               @gitkittie/core — GitFolder's TypeScript contract
  gitkanban-core/     @gitkittie/gitkanban-core — GitKanban board schema + logic (TS, tested)
swift/
  GitKittieKit/             Shared Swift package: the GitEngine, board model, and app services (implemented + tested)
docs/                 GitFolder product docs
```

> **Shared engine.** `swift/GitKittieKit` is the shared Swift package native apps depend on
> (git engine, config store, keychain, GitHub OAuth, folder access, and future GitBud history
> primitives). Extracting GitFolder's inline services into it is tracked work — see the GitKittie
> tasks board.

## GitFolder

Automatic version history for your folders. A macOS menu-bar app that versions selected
folders with GitHub on an interval, creating quiet snapshot commits when files change.

Docs: [product spec](docs/product-spec.md) · [data model](docs/data-model.md) ·
[implementation plan](docs/implementation-plan.md) · [sync model](docs/sync-model.md) ·
[App Store & business model](docs/app-store.md) · [phase 1](docs/phase-1.md) ·
[GitHub access](docs/github-access.md) · [macOS permissions](docs/macos-permissions.md) ·
[edge cases](docs/edge-cases.md) · [future phases](docs/future-phases.md)

## GitKanban

Your kanban board is a git repo. A native macOS/iOS kanban app backed by markdown files in a
git repository you own — full history, no server, portable by default. The board schema,
config inheritance, and card logic live in [`packages/gitkanban-core`](packages/gitkanban-core/),
and the full plan lives in the `project-assets` repo under `GitKittie/GitKanban/plan/`.

The canonical board format is the shared Tasks contract (`project-assets/Tasks/README.md`):
root/project configuration with inheritance, and markdown cards with YAML frontmatter.

## GitBud

Simple visual git history editing. GitBud is a native macOS git client in active development for
branch flows, commit graphs, file history, interactive rebase, commit splitting, squashing/merging,
reordering, Magic commit-message drafting via AIPont-style BYOK provider calls, and safe
full-history purge workflows.

macOS supports local repositories and GitPont-connected remotes cloned into app-managed checkouts
for full history editing. iOS and iPadOS are planned as remote-only clients through GitPont: repo
browsing, branches, diffs, file history where available, Magic, and branch/PR workflows without
shell git or local clone history surgery. GitBud has no accounts, hosted backend, or GitBud-owned
sync infrastructure.

Docs: [macOS features](apps/gitbud-macos/docs/Features.md) ·
[macOS architecture](apps/gitbud-macos/docs/Architecture.md) ·
[macOS decisions](apps/gitbud-macos/docs/Decisions.md) ·
[product spec](apps/gitbud-macos/docs/product-spec.md) ·
[implementation plan](apps/gitbud-macos/docs/implementation-plan.md) ·
[iOS/iPadOS features](apps/gitbud-ios/docs/Features.md) ·
[iOS/iPadOS architecture](apps/gitbud-ios/docs/Architecture.md) ·
[iOS/iPadOS decisions](apps/gitbud-ios/docs/Decisions.md)

## Development

```bash
npm install                              # install all workspaces
npm run check                            # typecheck + test + build everything
npm run gitkanban:core:test              # test the GitKanban core
npm run macos:generate                   # regenerate the GitFolder Xcode project
npm run gitbud:generate                  # regenerate the GitBud Xcode project
npm run gitbud:test                      # build GitBud tests and run GitBudTests.xctest
```
