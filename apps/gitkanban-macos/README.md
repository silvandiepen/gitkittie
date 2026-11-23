# Tasks (macOS)

The macOS **Tasks** app (formerly GitKittie Kanban) — a kanban board backed by a git repo of
markdown files. The product is `Tasks.app`; the target, scheme, module and bundle id
(`app.hakobs.gitkanban`) keep the GitKanban name.

**Status: working read/write board.** The app builds and runs today as a full GitHub-backed
kanban client: it connects to GitHub with device-flow OAuth, clones a repo it owns into its own
container, and renders, edits, and syncs a board of markdown cards. Every mutation is committed
and pushed. Generate the Xcode project with:

```bash
cd apps/gitkanban-macos && xcodegen generate
# or, to build + run in one step:
npm run gitkanban:run
```

### What it does today

- **Connects to GitHub** via device-flow OAuth and **owns its checkout**: it clones the chosen
  repo into `~/Library/Application Support/GitKanban/checkouts/<owner>-<name>`, pulls on reopen,
  and adopts an unborn branch on an empty repo. It is *not* a folder viewer.
- **Repo picker** with a "Last Used" shortcut and filter; multiple repos can be connected at once,
  and each can be disconnected.
- **Renders projects and their boards** from the checkout — a lane carousel (with focus scaling),
  a dockable backlog, a list view, and an **Uncategorised** column for cards whose status matches
  no lane. Cards show title, a colored priority chip, type icon, and `@assignee`.
- **Creates projects** (writes a `README.md` with config frontmatter + seeded lane folders) and
  **edits Project Settings** (rename/add/remove lanes with ticket migration, priorities, members).
- **Creates, edits, moves, reorders, and deletes cards.** Editing opens a card in its own
  **detail window** with field selects (lane / assignee / priority / type) and a description
  editor/preview. Card bodies are rendered as markdown in a `WKWebView` (Nizel).
- **Drag-to-move** cards between lanes and reorder within a lane, with optimistic UI and edge
  auto-scroll. **Multi-select** (⌘-click) supports bulk move / assign / delete.
- **Filters** (assignee / priority / type), **full-text search** (⌘F), and per-card **git
  history** (`git log --follow`).
- Moving a card **moves its file into the destination lane folder** and updates its `status` so
  folder and frontmatter stay in agreement (the canonical Tasks-board contract). Every action
  commits and pushes.

### Added in the Tasks update (2026-11)

Detail and status per item: [`docs/Features.md`](./docs/Features.md) → "Added in the Tasks update".

- **Boards load over the provider API or from a folder** (no clone), and on GitHub a lane's cards
  come in one request.
- **Sidebar:** board icons and colours, update counts, right-click menus, **Board Settings…**
  (name, icon, colour saved in the board's README), a board picker that lists the folders next to
  your boards, and "Add Board from…" in the + menu.
- **Task side panel without an edit mode:** editable title, Markdown description styled as you type,
  field chips as menus, a green check to save, swipe right to close, and "Open File".
- **Live updates** through the webhook relay ([`apps/gitkanban-relay`](../gitkanban-relay/)) for
  GitHub and GitLab.
- **Agent Access:** a local MCP server (plus a bridge that opens the app when it is closed) so
  agents list, create, claim and update cards, and create boards, without a copy of the
  repository. The board's rules are passed to the agent and its vocabulary is enforced.
- **Loading screen** with the animated Tasks mark.

## How it fits together

- **Board logic** comes from [`@gitkittie/gitkanban-core`](../../packages/gitkanban-core/) (TS,
  source of truth). Swift models mirror it.
- **Git, board parsing, and services** come from the shared [`GitKittie`](../../swift/GitKittieKit/) Swift
  package — `GitEngine`/`ShellGitEngine`, `BoardStore`/`BoardMarkdown`/`BoardModel`/
  `BoardInheritance`, `RemoteBoardStore`, `KeychainService`, `GitHubOAuthService`,
  `GitHubReposService`, `CardText`.
- **Board format** is the canonical contract in
  `/Users/silvandiepen/Repositories/tasks/README.md` (folder-per-lane; card frontmatter + root/project
  config with inheritance).
- **Phase 1 scope** (macOS, shell-out git, GitHub) is in
  `/Users/silvandiepen/Projects/GitKittie/GitKanban/plan/phase-1.md`.

## Structure

```txt
GitKanban/
  App/        GitKanbanApp (entry, commands, task-detail WindowGroup), AppModel (state), RootView
  Board/      BoardView, WorkspaceView, CardDetailView, TaskDetailWindow, FilterBar,
              SearchSheet, TaskHistorySheet, MarkdownWebView, BoardColors
  Connect/    ConnectView (device-flow), RepoPickerView
  Project/    NewProjectSheet, NewTaskSheet, ProjectsEmptyState
  Resources/  markdown-renderer.html
webview/      renderer.ts + esbuild build (bundles the markdown renderer)
scripts/      run.sh (npm run gitkanban:run)
```

`AppModel` is the single UI-facing `@Observable` state object. It reads boards through GitKittie's
`BoardStore`, writes card files directly (frontmatter composed in `AppModel`), and drives git
through `ShellGitEngine`. There is no separate `MarkdownStore`/`BoardSyncEngine` layer — those
responsibilities live in GitKittie (`BoardStore`/`BoardMarkdown`) and in `AppModel` respectively.

> **Known gaps / drift from the plan** (tracked on the GitKittie board): reordering currently uses an
> integer `order` and rewrites the affected lane rather than minting a single fractional rank key;
> card writes compose frontmatter by hand rather than round-tripping through Yams; there is no
> Swift test target yet; background interval sync and a conflict-resolution UI are not built (each
> action commits+pushes immediately, last-writer-wins).
