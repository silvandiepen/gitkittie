# GitKittie — Agent Instructions

Entry point for any agent (or human) working in this repo. Read this first, then the
per-app `AGENTS.md` for whichever app you're touching.

GitKittie is a **monorepo for git-backed apps**: three products — **GitFolder**, **GitKanban**,
and **GitBud** — each targeting Apple platforms, plus a marketing website, all sharing one git
engine. The products are local-first or remote-provider-first depending on platform, own-your-data,
no-server apps that treat a git repository as the source of truth.

## The apps (+ site)

| App | Home | Platform | Status |
|---|---|---|---|
| GitFolder (macOS) | `apps/gitfolder-macos/` | SwiftUI/AppKit menu-bar app | Shipping (App Store) |
| GitFolder (iOS) | `apps/gitfolder-ios/` | SwiftUI (planned) | Roadmap — libgit2 spike + plan |
| GitKanban (macOS) | `apps/gitkanban-macos/` | SwiftUI board app | In development (read-only board UI) |
| GitKanban (iOS) | `apps/gitkanban-ios/` | SwiftUI (planned) | Roadmap — Phase 2 |
| GitKanban server | `apps/gitkanban-server/` | Node + Hono file server (tailnet-only) | In development |
| GitBud (macOS) | `apps/gitbud-macos/` | SwiftUI git client | In development — tested local history/rewrite UI |
| GitBud (iOS/iPadOS) | `apps/gitbud-ios/` | SwiftUI remote git client (planned) | Docs/spec — GitPont remote-only |
| GitKittie Mail (macOS) | `apps/gitmail-macos/` | SwiftUI mail client, core in `swift/GitKittieMailKit` | In development — store + empty window |
| Website | `apps/website/` | Vue 3 + Vite | Shipping |

Each app folder carries its own `AGENTS.md` and `docs/{Features,Decisions,Architecture}.md`.
When a per-app rule conflicts with this file, **the per-app file wins**.

## Repository layout

```txt
apps/
  gitfolder-macos/    GitFolder — macOS menu-bar app (SwiftUI/AppKit, XcodeGen)
  gitfolder-ios/      GitFolder — iOS app (planned; docs/spec only)
  gitkanban-macos/    GitKanban — macOS board app (read-only board UI)
  gitkanban-server/   GitKanban file server — one local folder over Tailscale (Node + Hono)
  gitkanban-ios/      GitKanban — iOS app (planned; docs/spec only)
  gitbud-macos/       GitBud — macOS git client (SwiftUI/AppKit, XcodeGen)
  gitbud-ios/         GitBud — iOS/iPadOS remote git client (planned; docs/spec only)
  website/            Marketing/docs site (Vue 3 + Vite)
packages/
  core/               @gitkittie/core — GitFolder's TypeScript config contract
  gitkanban-core/     @gitkittie/gitkanban-core — GitKanban board schema + logic (TS, tested)
swift/
  GitKittieKit/             Shared Swift package: GitEngine + app services (config, keychain, OAuth)
docs/                 Global GitKittie docs + GitFolder product plans
```

**Dependency rule (hard):** apps depend on packages, **never on each other**. Shared logic
belongs in a package — `swift/GitKittieKit` (Swift) or `packages/*` (TypeScript) — not a cross-app
import. TypeScript is the source of truth for the board/config contracts; the Swift apps mirror
those packages, they do not fork them.

**GitPont is the only gateway to a git host (hard).** No GitKittie product talks to GitHub, GitLab,
Forgejo/Gitea, Bitbucket or any other host by itself: no provider URLs, no REST or GraphQL calls,
no `if provider is GitHub` branches in an app or in `swift/*`. A product says *what* it wants
("commit these files to this branch", "read this folder") and
[GitPont](https://github.com/silvandiepen/git-pont) (`~/Repositories/_libs/git-pont`) decides which
calls that takes on each host. That is the point of it: when GitPont gains a host, every product
works on that host without a change here.

- **GitPont is missing something?** Add it to GitPont, for every provider it can be done on, with
  tests there, then use it here. GitPont is our product too. Never work around a gap with a direct
  call in a product, not even "for now" with a TODO.
- **A capability a host cannot offer** is a GitPont capability flag
  (`provider.capabilities.contains(.batchCommit)`); the product asks the flag and falls back, it
  does not ask which host it is on.
- **Known debt** (direct host calls that predate this rule and still have to move), all in
  `swift/GitKittieKit`: `GitHubOAuthService.swift` and `GitHubReposService.swift` (GitFolder Mac and
  Bud; GitPont already has sign-in and repository lists), `GitHubPullRequestService.swift` (Bud;
  GitPont has no pull request reviews yet) and `GitHubSyncClient.swift` (used by nothing but its
  own tests). Do not add to this list.

## Where the plans and tasks live

- **Product plans & specs:** the `project-assets` repo under `GitKittie/` (`GitKittie/Gitfolder/`,
  `GitKittie/GitKanban/plan/`; GitBud docs currently live under `apps/gitbud-*`). The code repo's
  `docs/` mirrors the GitFolder product docs.
- **Task board:** the `GitKittie` board in `project-assets/Tasks/GitKit/` (canonical format:
  `project-assets/Tasks/README.md`). Cards carry a `GITKIT-###` or `GITFOLDER-###` id and an
  `epic:` (`gitfolder`, `gitkanban-core`, `gitkit-swift`, `gitkanban-macos`, `gitkanban-ios`,
  `monorepo-setup`). Every board mutation is committed and pushed.

## Build, test, run

```bash
npm install                 # install all JS/TS workspaces
npm run check               # typecheck + test + build every workspace (what CI runs)
npm run gitkanban:core:test # test the GitKanban core package
npm run site:dev            # run the website locally
npm run macos:generate      # regenerate the GitFolder Xcode project (XcodeGen)
npm run gitbud:generate     # regenerate the GitBud Xcode project (XcodeGen)
npm run gitbud:test         # build + test the GitBud macOS app
```

Swift apps use **XcodeGen** — never hand-edit `.xcodeproj`; edit `project.yml` and regenerate.
CI (`.github/workflows/`): `check.yml` (npm), `macos-native.yml` (build+test GitFolder),
`swift-gitkittiekit.yml` (GitKittie package), `deploy-website.yml` (Cloudflare).

## Conventions

These derive from Sil's baseline conventions (`project-assets/Agents/`); the load-bearing ones:

### Hard rules — no exceptions
- **Never** add a `Co-Authored-By: Claude` (or any AI) trailer to commit messages.
- **Never** `git commit`, `git push`, or `deploy` without the user explicitly asking in the
  current turn. "Looks good"/silence is not permission. **Board** changes in `project-assets`
  are the one exception — the board contract requires mutations be committed and pushed.
- **Never mock** in place of a real implementation. Implement the real thing or say you can't.
- **Never work around errors** — no removing imports, catch-and-ignore, `@ts-ignore`,
  disabling a check, or deleting a failing test to go green. Fix the root cause.
- **Never commit secrets** — tokens, keychains, `.env`, certificates, private keys.
- **Never** force-push, skip hooks (`--no-verify`), or amend a commit you didn't create this session.

### Style
- **Conventional Commits**, always: `type(scope): imperative subject` (`feat`, `fix`, `chore`,
  `refactor`, `style`, `docs`, `test`, `release`). Scope = affected app/module. Body explains *why*.
- **Reuse before you build** — check for an existing component/util/package before adding a
  parallel one. Match the surrounding code's idiom.
- **TypeScript:** `strict: true`, `interface` over `type` for object shapes, avoid `any`,
  named exports for utils/services. 2-space indent, double quotes, semicolons.
- **Swift:** SwiftUI + `@Observable`; keep `AppModel` the single UI-facing state object;
  domain/services stay UI-agnostic so the same layer can back macOS and iOS.
- **Website CSS:** SCSS + BEM (via `bemm`), no Tailwind, no `<style scoped>`; use `@sil/ui`
  tokens — see `apps/website/AGENTS.md`.

### Priority order when trade-offs conflict
correctness/security/privacy > architecture clarity > maintainability > extensibility >
developer convenience. Avoid premature complexity; don't design for hypothetical requirements.

### Assumption discipline
When the spec doesn't cover something and you make a judgment call, record it — in the app's
`docs/Decisions.md` or the PR description, not silently.

## Branching

`main` and `development` are the CI-protected branches. Feature/agent work happens on a branch
(the repo uses `claude/*` branches) and lands via PR. Prefer the clean current shape of the
product over backwards-compat shims — these apps have no external API consumers yet.
