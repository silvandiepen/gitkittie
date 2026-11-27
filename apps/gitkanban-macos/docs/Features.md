# Tasks (macOS) — Features

> **Name.** The app is called **Tasks** (`Tasks.app`, "GitKittie Tasks" on the website and store).
> It was GitKittie Kanban before. The target, scheme, Swift module, bundle id
> (`app.hakobs.gitkanban`) and this folder keep the GitKanban name, and so does the rest of this
> document.

GitKanban is a native macOS kanban board whose **only data source is a git repository of
markdown files**. There is no product backend and no hosted database: the board *is* a folder
in a git repo the user owns, hosted wherever they host git. Every edit is a change to a file and
a commit; sync is `git pull` / `git push` against the user's own remote.

> Working tagline: *your kanban board is a git repo.*

## Status legend

| Mark | Meaning |
|---|---|
| **Exists** | Implemented and running in the app today. |
| **Planned** | Specced in the plan / tracked on the GitKittie board; not built yet. |

The macOS **app builds and runs a working read/write board**. It connects to GitHub with
device-flow OAuth, clones the chosen repo into an app-owned checkout, and renders, creates, edits,
moves, reorders, deletes, filters, searches, and syncs cards — committing and pushing every
mutation. The board *logic* it uses (schema, inheritance, ordering, validation) lives in the
TypeScript package [`@gitkittie/gitkanban-core`](../../../packages/gitkanban-core/) and is mirrored in
`swift/GitKittieKit`; the board *format* is the canonical contract in
`/Users/silvandiepen/Repositories/tasks/README.md`. What remains **Planned** is background interval
sync, a conflict-resolution UI, and fractional rank keys in the app; see
[Architecture.md](./Architecture.md) for what is on disk versus tracked.

---

## The board model

A GitKanban board is one git repo (or a folder inside one) of markdown card files, laid out as
**one folder per lane**, plus a board config defined as README frontmatter. The core concepts:

| Concept | Definition | Status |
|---|---|---|
| **Board / project** | A git repo the app clones; each project is a folder of lane folders + a README config. Multiple repos and projects are supported. | Core: Exists · App: Exists (connect, clone, multi-repo, multi-project) |
| **Column (lane)** | A **folder** (`1. To do/`, …) whose cards carry a matching `status`. Folder and `status` must agree. | Core: Exists · App: Exists (render + move) |
| **Card** | **One markdown file** = one card: YAML frontmatter (structured fields) + markdown body (human prose, rendered as markdown). | Core: Exists · App: Exists (render + edit) |
| **Config** | Root + per-project frontmatter (`lanes`, `users`, `priorities`, `types`, `epics`, `tags`) with inheritance. | Core: Exists · App: Exists (read + write via create/settings) |
| **History** | Per-card journey read from git (`git log --follow`). | Engine: Exists · App view: Exists (history sheet) |

### Connect and own a repo
The app connects to GitHub with device-flow OAuth and **clones the chosen repo into its own
container** (`~/Library/Application Support/GitKanban/checkouts/<owner>-<name>`). It pulls on
reopen and adopts an unborn branch on an empty repo. It is not a folder viewer; it owns and syncs
its checkout. Multiple repos can be connected and disconnected, with a "Last Used" shortcut in the
repo picker. **Exists.** (Auth is GitHub-only for now; other providers are Planned.)

### Column = a lane folder (status must match)
Following the canonical Tasks contract, each lane is a folder and every card's `status` matches its
lane folder. **Moving a card between lanes moves its file into the destination lane folder and
updates `status`** so the two stay in agreement. `groupIntoColumns` builds columns in lane order and
puts any card whose `status` matches no lane into an `uncategorised` bucket rather than dropping it.
Core: **Exists**. Rendering (lane carousel + Uncategorised): **Exists**. Drag-to-move and bulk
move: **Exists**.

### One card = one file (frontmatter cards)
A card is YAML frontmatter for machines + a markdown body for humans. The modelled fields the app
edits are `id`, `title`, `project`, `status`, `priority`, `type`, `epic`, `assignee`, `order`.
**Unknown keys are preserved verbatim** on write (see below). The full canonical card schema — the
lifecycle fields (`picked_up_by`, `reviewer`, `testing_owner`, …) and required body sections — is
in `/Users/silvandiepen/Repositories/tasks/README.md`; GitKanban renders and edits a board of exactly
that shape. Parse/field-reading: **Exists** in core. Card editor UI (own detail window, field
selects, description edit/preview, markdown-rendered body): **Exists**.

### Config inheritance (root → project)
Configuration lives as README frontmatter at two levels and resolves to an **effective config**:

- **Root** (`Tasks/README.md`) — defaults for every project.
- **Project** (`Tasks/<project>/README.md`) — per-project overrides.
- **Lanes → replace.** A non-empty project `lanes` list fully replaces the root lanes (a custom
  workflow); empty/absent inherits root lanes. Lane folders must match the effective lanes.
- **Vocabularies → merge.** `users`, `priorities`, `types`, `epics`, `tags` extend the root set;
  a project entry with the same `id` wins.

Implemented as `resolveEffectiveConfig(root, project)`. Core: **Exists**. The app also **writes**
config: creating a project seeds its README frontmatter + lane folders, and Project Settings edits
lanes (with ticket migration when a lane is renamed/removed), priorities, and members. App:
**Exists**.

### Ordering within a lane
- **Core capability:** fractional rank keys (`order`) for free-form drag-reordering — inserting
  between two cards mints one key between the neighbours', so only the moved card is rewritten.
  Wrappers over `fractional-indexing`. Core: **Exists**.
- **What the app does today:** the app stores an **integer `order` (`index + 1`)** and rewrites the
  affected lane's cards on reorder rather than minting a single fractional key. Priority +
  `created_at` + `id` is the fallback for boards without an `order`. App reorder UI: **Exists**;
  adopting the fractional key path is **Planned** (tracked on the board).

### History from git
Per-card history comes from `git log --follow` on the file — "who moved this and when" for free.
The shared engine exposes `fileHistory(at:file:limit:)`, and the app surfaces it in a **history
sheet**. Engine: **Exists**. App view: **Exists**.

### Filters, search, list view, multi-select
- **Filters** by assignee / priority / type (`FilterBar`). **Exists.**
- **Full-text search** across cards (`SearchSheet`, ⌘F). **Exists.**
- **List view** as an alternative to the lane carousel, plus a dockable backlog. **Exists.**
- **Multi-select** (⌘-click) with bulk move / assign / delete (`SelectionBar`). **Exists.**

### Validation
`validateCard` checks a card against its effective config: required `id`/`title`/`status`, a
`status` that matches a lane, and `priority`/`type`/`assignee`/`epic` that reference configured ids.
Core: **Exists**.

### Additive / lenient frontmatter
Unknown frontmatter and config keys should round-trip untouched, so agents (sills), CI, and other
tools can add fields GitKanban does not model without data loss. Core parse/serialize: **Exists**.
Caveat: the app currently composes frontmatter with hand-rolled string editing rather than routing
writes through Yams; hardening round-trip fidelity (a zero-diff read-then-write) is **Planned**
(tracked on the board).

### Legacy compatibility (body-section field source)
Boards that keep fields as `**Label:** value` lines in a markdown section (the legacy `audit/tasks`
format) are read via a `body-section` field source — no migration needed. `resolveCardFields`
honours the config's `fieldSource`. Core: **Exists**; the app auto-detects this legacy format when
loading a board.

---

## Added in the Tasks update (2026-11)

Everything in this section is **Exists** in code on `feat/gitkanban-folders-review` and covered by
the tests named; "not clicked through" means the screen was built and compiles but was not
exercised by hand in that session.

> **Transport note.** The app reads and writes boards over the provider API through
> `swift/GitKanbanKit` (`GitPontFileSource`), or straight from a folder — it does not clone. The
> sections above that describe an app-owned checkout predate that and are due a rewrite.

| Feature | What it is | Status |
|---|---|---|
| **Loading screen** | The animated Tasks mark, "Tasks", "by GitKittie"; no title bar while it shows, centred in the window (`TasksMark.swift`, `SplashView`). | Exists |
| **Board loading on GitHub** | A lane's cards arrive in one GraphQL request instead of one request per card (`BulkTextSource`, `GitPontFileSource.readTexts`). GitLab still reads card by card. | Exists · measured: 143 cards in ~3 s |
| **Cards with a broken header** | Frontmatter that is not valid YAML is read line by line, so the card keeps its fields; a card with no title shows its first heading, then its file name (`BoardStore.lenientFields`, `CardTitleTests`). | Exists |
| **Switching boards** | The previous board is cleared and a loader names the board being read; the sidebar row shows a spinner. | Exists |
| **Sidebar** | Board icon and colour, a count of cards new or moved since the board was last opened, right-click menus on boards (Open, Reload, Board Settings…, Browse Boards…, Remove from Sidebar) and on repositories. | Exists · not clicked through |
| **Board Settings** | Display name, icon and colour, saved as `project:`, `icon:` and `color:` in the board's `README.md`; "More Settings…" opens the full project settings (`BoardSettingsSheet`, `AppModel+Appearance.swift`, `BoardAppearanceTests`). Saving project settings no longer drops `review_path`, `icon` or `color`. | Exists |
| **Adding boards** | The board picker opens on the folders next to the existing boards, not-yet-added first, with a filter and "Add All"; the + menu has "Add Board from…" for repositories already in the sidebar. | Exists · not clicked through |
| **A folder without a board** | A folder with no cards in any lane says so, and offers "Use `<parent>/<name>` Instead" when a board of that name sits next to the other boards. | Exists · not clicked through |
| **Task side panel** | No edit mode: the title is always editable, the description is a Markdown editor styled while typing (`MarkdownSourceStyler`, taken from Lezin), the lane/priority/type/epic/assignee chips are menus, a green check saves (⌘↩), closing or switching cards saves, and a two-finger swipe right closes the panel (`CardDetailInspector`, `MarkdownEditor.swift`). The panel no longer renders the description through the web view; "Open in Panel" still does. | Exists · not clicked through |
| **Open the file** | A card's menu opens its `.md` in the default Markdown app: the real file for a folder board, a downloaded copy for a repository board. | Exists · not clicked through |
| **Live updates** | Board menu → Live Updates…: registers a channel on the relay (`apps/gitkanban-relay`), adds a push webhook on GitHub or GitLab, commits `.gitkanban/relay.json`; an open board then reloads on push (`Relay.swift`, `ProviderWebhook.swift`, `RelayTests`). | Exists · verified against a local and the deployed relay with signed test pushes; no real webhook created yet |
| **Screenshot to task** | Drop a screenshot (a file from Finder or the desktop, the floating screenshot thumbnail, or image data from another app) on a lane, or anywhere on the board for To do: the New Task sheet opens with it, to mark up (`ImageMarkupEditor`, shared with iOS) and have the title and description drafted, as on the iPhone. The card gets the image in `<project>/attachments/<id>/screenshot-<stamp>.png` and the marks under its description (`TaskImage`, `AppModel+ImageTask.swift`, `ImageTaskTests`). | Exists · not clicked through |
| **Screenshot on the Dock icon** | Drag images (a screenshot, its floating thumbnail) onto the Tasks Dock icon, or Open With → Tasks: New Task opens with them on the open board, in its first open lane; with no board open it asks which board; while the sheet is up they join it. Works when Tasks was not running: the images wait until the last board is reopened. Images are declared as document types (Viewer, rank Alternate, so Tasks never becomes the default image app); `TasksAppDelegate.application(_:open:)` → `AppModel.openFiles` → `startTask(fromImages:)` (`AppModel+OpenedImages.swift`, `OpenedImagesTests`). | Exists · not clicked through |
| **Agent Access** | Account menu → Agent Access…: a local MCP server so agents use the boards without a copy of the repository. See [`../AGENTS.md`](../AGENTS.md) → Agent access. | Exists · verified with Claude Code and Codex against the real board |

### File storage in a bucket

A repository can send its images, audio, video and other binary files to an
S3-compatible bucket (Cloudflare R2, AWS S3), so the repository holds tasks, review
requests and pointers, not media. Repository menu → **File Storage…** (Mac and iPhone).

- **Settings** live in the repository, in `.tasks/storage.json`: endpoint, bucket, region
  and an optional public address. Every device and every agent reads the same file.
- **Keys** stay in the Keychain of each device, never in the repository.
- **Writing:** a binary file written through the provider (a task attachment, a review
  file, an annotated image, also by an agent through Agent Access) is uploaded as
  `tasks/v1/objects/<aa>/<sha256>.<ext>` and checked; the repository gets a small JSON
  file `<name>.bucket` with the key, hash, size and public link. The same content is
  uploaded once.
- **Reading:** the apps show `<name>` as before. The repository is tried first, so files
  from before the bucket still open; then the pointer is followed, and the download is
  checked against its hash. With a public address no keys are needed to read.
- **Without settings or without keys** a file is written to the repository as before.
- **Existing files** can be moved from the same screen, two commits per file. They stay
  in git history: moving stops growth, it does not shrink the repository.
- **Not covered:** folders on the device and folder servers keep their files in place.

The S3 code (`S3StorageService` in GitKittieKit) is shared with GitKittie Folder.

### Agent Access in short

- **Transport:** loopback HTTP (`POST /mcp`, default port 47810, bearer token) plus a stdio bridge
  script the app writes (`AgentAccess/tasks-mcp.sh`), which opens the app when it is closed.
- **Tools:** `list_boards`, `create_board`, `get_board`, `get_board_rules`, `list_cards`,
  `get_card`, `create_card`, `update_card`, `claim_card`, `attach_file`.
- **Rules reach the agent:** `get_board_rules` returns the repository's `README.md`,
  `TASK_TEMPLATE.md`, `AGENTS.md` and `RULES.md`, and the board's own `README.md`, `AGENTS.md` and
  `RULES.md`; the board's files win.
- **Vocabulary is enforced:** a `priority`, `type`, `epic`, `assignee` or `status` the board's
  effective config does not have is refused (`AgentBoard.validate`).
- **Every board of an added repository is reachable**, not only those in the sidebar; a board joins
  the sidebar on first use, and `create_board` makes a new one that inherits the repository's lanes.
- **Tests:** `AgentAccessTests` (a real MCP conversation over HTTP against a folder board).
- **`tasks` command-line tool** (GITKITTIE-124): the same tools from a terminal, for agents without
  the MCP tools and for people (`tasks list --board GitKittie --lane in-progress`, `tasks show
  GKM-123`, `tasks update GKM-123 --description "…"` or `'{"description": "…"}'`, `tasks move GKM-123
  review`, `tasks claim`, `tasks comment`, `tasks reviews`, `tasks raw <tool> '<json>'`). Tables and
  cards by default, `--json` for scripts; exit codes 1 refused · 2 usage · 3 app unreachable · 4 token
  refused · 5 not set up. It reads the bridge's `connection.json`, opens Tasks in the background when
  nothing listens, and finds a card's board from its id prefix (cached). Ships inside the app at
  `Contents/Helpers/tasks`; Agent Access ▸ **Install Command-Line Tool…** links it into
  `~/.local/bin` and shows the PATH line. Code: `swift/GitKanbanKit/Sources/TasksCLIKit` (+
  `TasksCLI`, `TasksAgentTools`); tests: `TasksCLIParsingTests`, `TasksCLIIntegrationTests`.

---

## Sync

The write loop runs on every mutation: edit writes the affected card file(s) → **commit per
logical action** with a descriptive message → **`pull --rebase` then `push`** via `ShellGitEngine`.
This is **Exists** and immediate (each action syncs at once). What remains **Planned**:

- **Background interval sync** and explicit per-board status states (synced / syncing / offline /
  needs-attention / conflict).
- **Conflict surfacing UI.** Writes are currently immediate and effectively last-writer-wins; a
  conflict-detection + recover-from-history resolver is not built. The `GitEngine` primitives it
  would build on (`pullRebase`/`status`/`fileHistory`) **Exist**.

---

## Agents & external writers (Exists by construction)

Because the board is just files in a repo the app clones, agents, CI, and scripts write cards and
push like any other client; GitKanban pulls and the new/changed cards appear. The
lenient-frontmatter rule means an agent can add fields the app does not model and they survive. This
"a human curates in a native UI, a fleet of agents populates through git" loop is the primary
differentiator — and it already runs headless on the live `/Users/silvandiepen/Repositories/tasks`
board today.

---

## Non-goals (early)

- Realtime multiplayer / live cursors — git is not a realtime backend.
- A hosted service or accounts — the user brings their own git host.
- A full PM suite — no gantt, sprints-with-burndown, or time tracking in v1.
- Providers beyond **GitHub** on macOS in v1 (the iOS app adds GitLab / self-hosted via git-pont).
- Windows / Linux / web — Apple platforms first.

See [Decisions.md](./Decisions.md) for why these choices were made and
[Architecture.md](./Architecture.md) for how the pieces fit.
