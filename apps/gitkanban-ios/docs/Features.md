# Tasks (iOS) — Features

> The app is called **Tasks** (formerly "Kanban"). This document keeps the GitKanban name for the
> code: target, scheme, module and bundle id are unchanged.

GitKanban iOS is a working read/write kanban board that talks to a git host over its REST API
(through git-pont) — no local clone. It ships the **same board contract as macOS**, so a board
authored or edited on one platform renders on the other. Where a feature is not built yet, it is
marked **Planned**; where the plan is silent on an iOS specific, the entry says **Open**.

## Status legend

| Mark | Meaning |
|---|---|
| **Done** | Implemented and running in the app today. |
| **Planned** | Specced / tracked on the GitKittie board; not built yet. |

## Guiding contract (inherited, not re-invented)

- A board is a repo of markdown card files; **a lane is a folder** and a card's `status` matches its
  lane folder (they must agree).
- One card = one markdown file (YAML frontmatter + markdown body).
- Config inheritance (`root` → `project`): lanes **replace**, vocabularies **merge**.
- Unknown frontmatter/config keys are **preserved on round-trip**.

All of the above is owned by [`@gitkittie/gitkanban-core`](../../../packages/gitkanban-core/)
(TypeScript, the source of truth) and mirrored into Swift (`swift/GitKittieKit`). iOS consumes that mirror
via `RemoteBoardStore` + `BoardFileSource` — it does not fork the schema.

## Feature set

| Feature | What it is on iOS | Status | Notes |
|---|---|---|---|
| Connect | GitHub / GitLab.com / self-hosted GitLab with a **personal access token** | Done | Validated via `provider.account`; token in Keychain, provider in UserDefaults; auto-restore |
| Repositories | List + search the account's repos; pick one | Done | Via git-pont |
| Open a board | Load workspace/projects over the API — **no clone** | Done | `GitPontFileSource` + `RemoteBoardStore` |
| Multi-project | Switch projects when a repo has several | Done | Project switcher in `BoardScreen` |
| Board rendering | **Kanban lanes or a grouped list** (toggle), backlog lanes ordered last, Uncategorised column | Done | `BoardScreen` `viewMode`; lane color/count, priority chips, id/`@assignee` |
| Create card | New `.md` with frontmatter + slug id, committed | Done | `NewTaskSheet` → `commitFile` |
| Edit card | Fields + body; moving lanes = write new path + delete old; description rendered as Markdown in the detail | Done | `CardSheets`, native `MarkdownView` |
| Move between lanes | Rewrite `status`, write new path, delete old | Done | Via edit; **no drag-and-drop** — a lane picker |
| Reorder within a lane | Drag (`onMove`) rewrites `order` frontmatter; only changed cards commit | Done | `AppModel.reorderCards`, `BoardScreen` `onMove` (integer `order`, not fractional keys) |
| Delete card | Swipe action or confirm dialog | Done | `deleteFile` |
| OAuth sign-in | Provider OAuth instead of a pasted PAT | Planned | PAT-only today; `RootView` notes per-server OAuth as future |
| Per-card history | "Who moved this and when" | Planned | Would need a provider commit-history call |
| Offline / local-first | Create and edit without a connection; changes wait in an outbox and are sent later | Done | `Outbox.swift` (`OutboxSource`, `ReadCache`), `OutboxTests`; unverified against a real host on a device |
| Git sync / conflict | Sync states, conflict surfacing | Planned | Writes are sent in the background but still **last-writer-wins**; a refused write stays in the activity view to retry or discard |
| Share to Tasks | Share a screenshot/photo from any app; also an "Add to Tasks" action | Done | `ShareExtension/`, `ActionExtension/`; App Group `group.app.hakobs.gitkanban`; confirmed on a device |
| Pick project and task | Last used project suggested; new task or add to an existing one | Done | `ShareModel`, `ShareFlowTests` |
| Image markup | Select a region, comment on it, quick suggestions incl. the text found in the region | Done | `Shared/AnnotationEditor.swift`, `ImageTextReader` (Vision OCR) |
| Auto draft | Title, description, type and priority drafted from the image and comments; "Enhance" redrafts | Done | `ImageTaskDrafter`, `AIPontMagic.generateTickets(…images:)`; needs a model (below) |
| On-device AI | Apple Foundation Models; text only, works from OCR text and image labels | Done | `OnDeviceAI.swift`, `OnDeviceAITests`; Apple Intelligence devices only |
| Cloud vision | OpenAI, Anthropic or Gemini with the user's key; the image is sent | Done | Request shapes tested; no live provider call verified |
| Device details | Model, iOS version, screen size, appearance, text size added to the task | Done | `Shared/DeviceDetails.swift`; can be switched off per share |
| Images in New Task | Add images when creating a task in the app, same markup + drafting | Done | `NewTaskSheet`, `NewTaskImageUITests` |
| Background sending | Add/Create closes at once; a corner dot shows work in progress and opens the activity view | Done | `SyncViews.swift`, `AppModel+Sync.swift`, background task `app.hakobs.gitkanban.sync` |
| Seen / unseen | Mark on cards changed since you opened them; device-local | Done | `AppModel+Seen.swift`, `SeenStateTests` |
| Updated date | Shown on cards | Done | from `updated_at` |
| Sorting | Board Order, Unseen First, Last Updated, Priority | Done | `CardSort` |
| Board overview | Home screen shows counts of new/moved cards per board | Done | Listing-based `BoardSummary` (no card reads) |
| Move to another project | Same-named lane else the first; asks whether to renumber; file name follows | Done | `AppModel+MoveProject.swift`, `MoveProjectTests`; unverified on a device |
| Live updates | Board menu → Live Updates…; an open board reloads on push | Done | `Relay.swift`, `LiveUpdatesSheet`; GitHub + GitLab; open apps only |
| Faster loading | One request per lane on GitHub | Done | `BulkTextSource` |
| Robust card reading | Invalid YAML frontmatter still yields the card's fields; never an untitled card | Done | `BoardStore.lenientFields`, `CardTitleTests` |
| Loading screen | "Tasks · by GitKittie" with the animated mark | Done | `TasksMark.swift` |
| Board icon / colour | Set per board in its README | Planned | macOS shows and edits them; iOS does not yet |
| Agent Access | Agents working through the app | Planned | macOS only; needs a local listener |

## Platform-specific notes

- **Transport:** the provider's **REST API over HTTPS via git-pont** — `listDirectory`/`readFile`
  to read, `commitFile`/`deleteFile` to write. No local clone, no `git` binary, no libgit2.
- **Auth:** a user-supplied **personal access token** (not device-flow OAuth), stored in the iOS
  Keychain. Multi-provider (GitHub, GitLab.com, self-hosted GitLab).
- **Writes:** each mutation is a single commit, saved to an outbox first and sent in the background
  (also from the share extension, which hands unsent work to the app). Writes still overwrite
  (last-writer-wins) — there is no conflict detection yet.
- **Shared storage:** the app and its share/action extensions share boards, the connection and the
  token through the App Group and a shared keychain item (`GitKanbanSharedStorage`).

## Explicit non-goals (mirror the product spec)

- No realtime multiplayer.
- No hosted service or accounts — the user brings their own git host and token.
- Not a full PM suite — no gantt, sprints/burndown, or time tracking.

## Not pursued

- **Embedded libgit2 / on-device git engine.** The plan originally gated iOS on a `Libgit2Engine`;
  the app shipped over the git-pont REST API instead. An embedded offline mode remains a possible
  later addition, not a prerequisite.
