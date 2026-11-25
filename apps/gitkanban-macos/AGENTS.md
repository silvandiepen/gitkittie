# GitKanban (macOS) — Agent Instructions

Read the root [`../../AGENTS.md`](../../AGENTS.md) first; this file adds GitKanban-macOS-specific
rules. It does not restate the global hard rules — they still apply.

## What this app is

A native macOS kanban board whose data source is a git repo of markdown files. Today the app
**builds and runs a working read/write board**: `GitKanban/App/GitKanbanApp.swift`,
`GitKanban/App/AppModel.swift` (the single UI-facing `@Observable` state object), and
`GitKanban/Board/BoardView.swift` connect to GitHub, clone a repo the app owns, and render, edit,
move, reorder, delete, filter, search, and sync a board of markdown cards. Every mutation commits
and pushes. See [`docs/Architecture.md`](./docs/Architecture.md) for what exists vs. what is
planned, and [`docs/Features.md`](./docs/Features.md) / [`docs/Decisions.md`](./docs/Decisions.md)
for the rest.

## Folder sources and review

Besides provider repos, an added entry can be a **local folder** (`LocalFolderSource`, macOS folder
picker) or a **GitKanban folder server** (`ServerFolderSource`, `apps/gitkanban-server`, usually over
Tailscale). Both do **no git**: the folder's own sync tool commits. The kind lives on `AddedRepo.kind`;
`AppModel.makeSource(for:)` picks the source. Review requests (`Review` in GitKittieKit, mirroring
`packages/gitkanban-core/src/review.ts`) load from the board's effective `review_path` and only show
when that folder exists. Reviewer writes are compare-and-swap so an agent's concurrent edit is never lost.
Both apps have review screens (`GitKanban/Review/`). Several files of a request can be chosen and decided or commented on
at once (Mac: ⌘A, checkbox, ⌘/⇧-click, Escape; iOS: Select in the request's ⋯ menu): `AppModel.decide(_:itemIDs:status:)` and
`comment(_:itemIDs:text:)` make it one write, and refuse approving two options of a pick-one group (`ReviewSelection.swift`).

## Rules specific to this app

- **Board logic is owned by `packages/gitkanban-core` (TypeScript is the source of truth).** Change
  the contract — schema, inheritance, rank keys, validation, field sources — **there first**, then
  mirror it in Swift. Never fork or re-invent the board logic in Swift; the Swift models mirror the
  TS package field-for-field so the macOS and (future) iOS parsers can't drift.
- **The canonical board format is `/Users/silvandiepen/Repositories/tasks/README.md`.** GitKanban
  renders a board of exactly that shape: **lanes are folders**, a card's `status` must match its
  lane folder, and config lives in root/project README frontmatter with inheritance. Treat it as
  the authoritative schema. Moving a card means moving its file into the new lane folder **and**
  updating `status`.
- **Git and board parsing come from `swift/GitKittieKit`,** not inline copies — `GitEngine`/
  `ShellGitEngine`, `BoardStore`/`BoardMarkdown`/`BoardModel`/`BoardInheritance`, `RemoteBoardStore`,
  `KeychainService`, `GitHubOAuthService`, `GitHubReposService`, `CardText`. Apps depend on
  packages, never on each other or on GitFolder.
- **Preserve unknown frontmatter keys.** Writes must round-trip untouched keys (a read-then-write
  of an unchanged card should be a zero diff). External writers (sills, CI, agents) add fields the
  app does not model; do not drop them. NB: card writes currently compose frontmatter by hand in
  `AppModel`; routing them through GitKittie/Yams and hardening round-trip fidelity is tracked on the
  board — keep that guarantee in mind when touching the write path.
- **XcodeGen only.** Never hand-edit the `.xcodeproj`. Edit `project.yml`, then regenerate:
  `cd apps/gitkanban-macos && xcodegen generate`.

## Where the plan and tasks live

- **Plan / spec:** `/Users/silvandiepen/Projects/GitKittie/GitKanban/plan/` (`README.md`,
  `product-spec.md`, `data-model.md`, `sync-model.md`, `architecture.md`, `platforms-and-git.md`,
  `implementation-plan.md`, `phase-1.md`, `risks-and-open-questions.md`).
- **Task board:** `/Users/silvandiepen/Repositories/tasks/GitKit/` — cards with a `GITKIT-###` id and
  `epic: gitkanban-macos` (app) or `gitkanban-core` (contract). Follow the board contract when
  mutating cards.

## Commands

```bash
npm run gitkanban:core:test                      # test the board logic (TS source of truth)
npm run gitkanban:webview:build                  # rebuild the markdown-renderer webview bundle
npm run gitkanban:run                            # build + run the macOS app (scripts/run.sh)
cd apps/gitkanban-macos && xcodegen generate     # (re)generate the Xcode project
```

## Agent access (MCP server)

The Mac app serves its boards to agents on the same Mac as an MCP server, so an agent needs no
copy of a board's repository. Account menu → **Agent Access…** turns it on and shows the command
that connects Claude Code.

- **Where:** `swift/GitKanbanKit` — `MCPServer.swift` (JSON-RPC for MCP + a loopback HTTP listener),
  `AgentBoard.swift` (what an agent can do with one board, over any file source),
  `AppModel+Agents.swift` (settings, token, the tool list and its wiring). UI: `AgentAccessSheet.swift`.
- **Transport:** `POST http://127.0.0.1:<port>/mcp` (default port 47810), plain JSON answers.
  Loopback only, bearer token from the keychain, any request with an `Origin` header refused.
  Needs the `com.apple.security.network.server` entitlement (`project.yml`).
- **Bridge:** when the server starts, the app writes `AgentAccess/tasks-mcp.sh` and
  `AgentAccess/connection.json` (port, token, this app's path; user-only permissions) into its
  Application Support folder. Agents run the script as a stdio MCP server
  (`/bin/bash <script>`): it forwards each JSON-RPC line over HTTP and, when nothing answers, opens
  this copy of the app in the background and retries. Opening by bundle id is not used first,
  because it can start an older installed copy. The script lives in `AgentBridge` in
  `AppModel+Agents.swift`; it uses only `bash`, `curl`, `plutil`, `nc` and `open`.
- **Writes go straight to the source** (provider API or folder), not through the outbox: a tool call
  that returns has landed. After a write the app reloads that board if it is on screen.
- **Cards are edited as text.** `AgentCardText.set` replaces top-level frontmatter keys and keeps
  every other line; ids, file names and commit messages follow the tasks board contract. Do not
  route agent writes through `CardText.update`, which quotes values as strings and cannot write
  `null`, booleans or lists.
- **Tests:** `AgentAccessTests` runs a real MCP conversation over HTTP against a real folder board.
  The provider path (GitHub/GitLab) shares the code but is not covered by a test.
