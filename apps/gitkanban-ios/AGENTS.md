# GitKanban iOS — Agent Instructions

Read the root [`../../AGENTS.md`](../../AGENTS.md) first; this file adds GitKanban-iOS-specific
rules. Global hard rules and conventions are not restated here.

## Status

**Working read/write board over an API transport.** The app is scaffolded and builds for the iOS
Simulator: connect (GitHub / GitLab.com / self-hosted GitLab via a personal access token) → repo
picker → board load → create/edit/move/delete cards. Transport is the provider **REST API via
[git-pont](../../../_libs/git-pont)** (no local clone, no `git` binary), **not** the
previously-planned `libgit2` engine — that gate is superseded and no `Libgit2Engine` exists.
Board parsing/model stays in shared `swift/GitKittieKit` (`RemoteBoardStore` + `BoardFileSource`); iOS
must not fork the schema or the board logic. An embedded-libgit2 offline mode is a possible later
addition, not a prerequisite. Writes are currently blind (last-writer-wins); reorder, per-card
history, offline, and conflict handling are not built yet.

## Folder sources and review

Besides provider repos, an added entry can be a **local folder** (`LocalFolderSource`, macOS folder
picker) or a **GitKanban folder server** (`ServerFolderSource`, `apps/gitkanban-server`, usually over
Tailscale). Both do **no git**: the folder's own sync tool commits. The kind lives on `AddedRepo.kind`;
`AppModel.makeSource(for:)` picks the source. Review requests (`Review` in GitKittieKit, mirroring
`packages/gitkanban-core/src/review.ts`) load from the board's effective `review_path` and only show
when that folder exists. Reviewer writes are compare-and-swap so an agent's concurrent edit is never lost.
Both apps have review screens (`GitKanban/Review/`). Select in a request's ⋯ menu shows its files as a grid to decide or
comment on several at once, in one write (`AppModel.decide(_:itemIDs:status:)`, `comment(_:itemIDs:text:)`); approving two options
of a pick-one group is refused. `UITests/ReviewSelectUITests` needs `scripts/seed-select-fixture.sh <simulator-udid>` first.
The home-screen name is **Tasks** (GITKITTIE-013 tracks the rest of the rename).

## Share extension and shared storage

`ShareExtension/` is the **Tasks** share target (`GitKanbanShare`, images only; `GitKanbanAction` registers the same sheet as the "Add to Tasks" action, and `Shared/` holds the markup editor and drafting both it and the app use): a screenshot becomes
a card on a chosen board and lane, with the image written to `attachments/<CARD-ID>/`. It creates the
card itself through `AppModel` (`restoreForSharing()`, `openBoard(…, transient: true)`,
`createTask` → id, `attachFile(toCardID:)`); it never hands off to the app.

- The app and the extension share state through the App Group `group.app.hakobs.gitkanban`
  (`GitKanbanSharedStorage`): defaults suite plus the token in the keychain under that access group.
  Both build their model with `AppModel.shared(…)`. The app migrates the pre-group defaults and
  keychain item once on launch; the extension never migrates. **Any new persisted key the extension
  needs must go through `AppModel.defaults`, not `UserDefaults.standard`.**
- Annotations (`AnnotationEditor`): boxes are stored normalized, drawn onto the attached image, and
  listed in the card body under `## Annotations`. Quick comments include the text Vision finds
  inside the box.
- AI: `.onDevice` (`OnDeviceAI`, Apple Foundation Models, iOS 26+) is text-only, so it works from the
  text `ImageTextReader` reads out of the screenshot. Only a configured cloud provider is sent the
  image (`AITicketService.generateTickets(images:)`), and only from the explicit "Analyze image" action.
- Activation (`NSExtensionActivationRule` in `project.yml`, the same for both targets): any
  attachment typed as an image, or typed only `public.data` / `dyn.…` with nothing that says it is
  text, other content or a web link. Apps share images both ways (a file named without an image
  extension registers `dyn.…` + `public.file-url`); `TaskImage` reads the bytes to tell.
  `UITests/ShareTargetUITests` opens the real share sheet on each representation through the
  DEBUG `-shareSheetProbe <kind>` launch argument (`GitKanban/App/ShareSheetProbe.swift`). It reads
  the iPhone sheet; the iPad's popover is not visible to XCUITest.
- `UITests/ShareScreenshotUITests` drives Photos → Share → Tasks (new task with markup, then adding
  to that task). Seed a board first with `scripts/seed-share-fixture.sh <simulator-udid>`; it skips
  when there is none.
- Releasing needs a provisioning profile for `app.hakobs.gitkanban.share` and the App Group on both
  ids in the fastlane hub. Not set up yet.

## Outbox: background sending and offline

Writes to a provider repo never go straight to the network. `AppModel.makeSource` wraps the provider
source in `OutboxSource` (GitKanbanKit `Outbox.swift`): a write is saved to the App Group container and
returns at once; reads are overlaid with what is still unsent, and fall back to the last copy read
when there is no connection. `AppModel.flushOutbox()` sends in order, one flush at a time across the
app and its extensions. It runs after every write, on launch, on foreground, when the network returns
and from the `app.hakobs.gitkanban.sync` background refresh. A connection failure leaves writes
waiting; a refusal marks that write failed until it is retried or discarded (`SyncFailures.swift` in
`swift/TasksUI`: Retry, Discard, Show What It Was, in the activity list and on the review screens).
`enqueue` throws when it cannot store the content, and nothing is queued then. Review requests are
not sent as whole files: the write carries the reviewer's `ReviewEdit`s, which are merged onto the
server's copy when sent, and writes to one request fold into one (`ReviewEdits.swift`, Decision 8). Folder sources and the demo are not wrapped. Consequences to keep in mind:
`errorMessage` after a write no longer means the provider accepted it, and GitHub must be read through
`UncachedHTTPClient` (a cached read hands back a stale version and the next write conflicts).

## Seen state, sorting and the boards list

`AppModel+Seen.swift` (GitKanbanKit). A card is *unseen* when `updated_at` is newer than the last time
it was opened on this device, its `read_at`, or the board's first open. Seen marks live in the shared
defaults, so opening a card never commits; `read_at` stays the explicit, repo-stored mark. `cardSort`
orders cards inside a lane or stage. The boards list is summarized from directory listings only
(`RemoteBoardStore.listing`): "N new" counts cards that are new or changed lane since the board was
last opened, not in-place edits. Do not read card files for the home screen: on GitHub that is one
request per card.

## What this app depends on (do not duplicate)

- **Git transport:** git-pont's `GitProvider` (`GitPontCore` + `GitPontGitHub`/`GitPontGitLab`),
  reached through `GitPontFileSource`, which conforms to GitKittie's **`BoardFileSource`**. iOS has no
  shell and cannot run the macOS subprocess engine. **Do not build a git engine or call
  `GitEngine`** — the board is loaded/written through `BoardFileSource` + `RemoteBoardStore`.
- **Board schema + logic:** [`@gitkittie/gitkanban-core`](../../packages/gitkanban-core/). **TypeScript
  is the source of truth**; Swift mirrors it (via `swift/GitKittieKit`). **Do not build a second
  board/schema abstraction** — reuse the shared one, as macOS does.
- **Board UI:** the iOS UI is **bespoke SwiftUI** written in this app (`RootView`, `BoardScreen`,
  `CardSheets`), not imported from macOS. Keep it thin over the shared model; do not fork board
  logic into the views.

## Where the plan and tasks live

- **Plan:** `/Users/silvandiepen/Projects/GitKittie/GitKanban/plan/` — `platforms-and-git.md` (the iOS
  git story), `architecture.md`. Local detail in [`docs/`](./docs/).
- **Tasks:** the `GitKittie` board, `/Users/silvandiepen/Repositories/tasks/GitKit/`, epic
  **`gitkanban-ios`**.

## When writing docs here

- Never present planned work as done; never fabricate concrete APIs. Where the plan is silent, write
  **Open**. Record any judgment call in [`docs/Decisions.md`](./docs/Decisions.md).
- Do not modify code or other apps' files from this directory.
