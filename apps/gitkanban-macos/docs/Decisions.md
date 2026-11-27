# GitKanban (macOS) — Decisions

An ADR-lite log of the load-bearing decisions behind GitKanban. Each entry records the
**Decision**, its **Context**, the **Rationale**, and a **Status** (accepted / proposed / open /
superseded). These are drawn from the GitKanban plan
(`/Users/silvandiepen/Projects/GitKittie/GitKanban/plan/`), the `@gitkittie/gitkanban-core` README, the
canonical board contract (`/Users/silvandiepen/Repositories/tasks/README.md`), and the shipped app.
Where the shipped implementation diverges from the original plan, that is called out explicitly.

---

### 1. TypeScript is the source of truth; Swift mirrors it

**Decision.** The board schema and logic live in `packages/gitkanban-core` (TypeScript, built and
tested). The Swift apps **mirror** this package (via `swift/GitKittieKit`); they do not fork or re-invent
the contract. To change the contract, change it in TypeScript first, then mirror the change in
Swift.

**Context.** GitKanban ships on macOS (shell git) and iOS (git-pont API). Two independently written
parsers would inevitably drift, corrupting boards differently on each platform.

**Rationale.** One reference implementation plus shared fixtures means the parsers cannot diverge.

**Status.** Accepted.

---

### 2. One card = one file

**Decision.** Each card is a single markdown file. Editing a card never touches another card's
bytes.

**Context.** Kanban is a stream of tiny state changes across many devices and writers (human +
agents). A shared `board.json` with an ordered array would be rewritten by every action.

**Rationale.** File-per-card isolates edits: two people working different cards merge cleanly.

**Status.** Accepted.

---

### 3. A column is a lane folder; a card's `status` must match its folder

**Decision.** A card's column is a **folder** (`1. To do/`, `2. In Progress/`, …), and the card's
`status` field must match its lane folder. **Moving a card moves its file into the destination lane
folder and updates `status`** in the same action, so folder and frontmatter always agree.

**Context.** An earlier plan draft had the column be *only* a `status` field, with the file staying
put ("moving a card does not move the file"). The live `Tasks/` contract, however, makes lane
folders the primary, human-browsable view and requires `status` to match — and the shipped app
follows that contract. So the app **does** move the file on a lane change.

**Rationale.** Folder-per-lane keeps the repo readable to humans and tools browsing the tree, and
the card's stable `id`/filename preserves `git log --follow` across the move. The `status` field
keeps the value machine-readable and lets `groupIntoColumns` place cards without walking the tree.

**Status.** Accepted (revised from the earlier "field, not folder" draft to match the canonical
contract and the shipped app).

---

### 4. Additive, lenient frontmatter — unknown keys are preserved

**Decision.** Parse/serialize should round-trip **every** frontmatter (and config) key verbatim,
including keys the app does not model. A read-then-write of an unchanged card should produce a zero
diff.

**Context.** Boards are written by external tools — sills audits, CI, scripts, agents — that add
fields GitKanban has never heard of. The canonical card carries a large lifecycle vocabulary
(`picked_up_by`, `reviewer`, `testing_owner`, …) beyond the fields the board UI reads.

**Rationale.** Preserving unknown keys means the app is one writer among many without being the
schema authority, keeping agents' diffs readable.

**Status.** Accepted in principle and honoured by the core (TS) parser. **At risk in the app:** the
macOS app currently composes frontmatter with hand-rolled string editing in `AppModel`
(`composeFrontmatter`/`setFrontmatterKey`/`composeCard`) rather than round-tripping through
`BoardMarkdown`/Yams. Routing writes through the shared layer and adding a zero-diff round-trip test
is tracked on the board.

---

### 5. Config inheritance: lanes replace, vocabularies merge

**Decision.** Effective config = root config overlaid with project config. A non-empty project
`lanes` list **replaces** the root lanes (custom workflow); `users`/`priorities`/`types`/`epics`/
`tags` **merge** (project entries extend root; same `id` → project wins). Implemented as
`resolveEffectiveConfig(root, project)`.

**Context.** The `Tasks/` contract defines configuration as README frontmatter at root and per
project, and the app consumes it as data — reading it to render and writing it via project
create/settings.

**Rationale.** Lanes are structural (replace); vocabularies are additive dimensions (merge).

**Status.** Accepted.

---

### 6. Ordering within a lane — fractional rank keys (core) vs integer `order` (app today)

**Decision (target).** Position within a lane is a fractional / lexicographic rank key stored as
`order` (wrappers over `fractional-indexing`); inserting between two cards mints one new key and
rewrites only the moved card. Boards without rank keys fall back to priority + `created_at` + `id`.

**Context.** "Between these two cards" is the classic distributed-order problem; integer positions
force a rewrite of every card below an insert and conflict when two clients insert nearby.

**Rationale.** Rank keys make an insert O(1) writes and O(1) diff. The fallback sort handles boards
(like the audit/task boards) that carry no `order`.

**Status.** Core: **Accepted and implemented** (`rank.ts`). App: **not yet adopted** — the macOS
app currently writes an **integer `order = index + 1`** and rewrites the affected lane on reorder.
This works but reintroduces the neighbour-churn the rank keys were meant to avoid. Adopting the
fractional key path in the app is tracked on the board.

---

### 7. Body-section field source for legacy boards

**Decision.** Support two field sources: `frontmatter` (native GitKanban format) and `body-section`
(read `**Label:** value` lines from a named markdown section — the legacy `audit/tasks` format).
The source is set in config and honoured by `resolveCardFields`.

**Context.** The existing audit boards store `State`/`Assignee`/`Branch·PR` in a `## Status` body
block. Hundreds of such files exist.

**Rationale.** GitKanban can open today's boards without rewriting files.

**Status.** Accepted. Core: implemented; the app auto-detects the legacy format.

---

### 8. Phase-1 scope: macOS, shell-out git, GitHub

**Decision.** Phase 1 is **macOS**, git via **shelling out to the system `git` binary** (behind the
`GitEngine` protocol), **GitHub only** for auth (device-flow OAuth + Keychain).

**Context.** The premise ("is a git repo of markdown a pleasant board?") is provable on one platform
with maximum reuse of GitFolder's macOS foundation.

**Rationale.** Prove the schema and sync model cheaply first.

**Status.** Accepted — and **exceeded** in scope: the shipped app owns its checkout, supports
**multiple connected repos and multiple projects per repo**, and ships create/edit/move/reorder/
delete, filters, search, list view, and multi-select. What is still Planned is background interval
sync, a conflict UI, and the fractional rank keys of Decision 6.

---

### 9. GitKanban lives in the GitKittie monorepo, sharing one git/board package

**Decision.** GitKanban is built inside the GitKittie monorepo alongside GitFolder, not as a forked
repo. Both apps depend on the shared `swift/GitKittieKit` Swift package (git engine, board parsing,
keychain, OAuth, repos service); board logic depends on `packages/gitkanban-core`. Apps never import
each other.

**Context.** An earlier draft recommended a standalone repo; that was reversed — the git engine and
board parsing are genuinely shared code.

**Rationale.** One repo means the two apps can't drift and one fix benefits both, while each still
ships to the App Store independently.

**Status.** Accepted.

---

### 10. `GitEngine` protocol boundary; shell-git on macOS

**Decision.** The macOS app calls git only through a `GitEngine` protocol
(`clone / pullRebase / commit / push / status / fileHistory`), implemented by `ShellGitEngine`
(subprocess `git`).

**Context.** iOS has no shell — the biggest platform delta. The protocol keeps the transport
swappable.

**Rationale.** The protocol boundary lets macOS move fast on shell-git while keeping the board UI
transport-agnostic.

**Status.** Accepted (protocol + `ShellGitEngine` exist and are used by the app). NB: iOS did **not**
implement `Libgit2Engine` behind this protocol — it ships over a REST API via git-pont using
GitKittie's `RemoteBoardStore`/`BoardFileSource` instead (see Decision 12 and the iOS app).

---

### 11. YAML frontmatter via Yams (Swift), `yaml` (TS)

**Decision.** The TS core parses/serializes frontmatter with the `yaml` package; the Swift board
parsing in `swift/GitKittieKit` uses **Yams**.

**Context.** Frontmatter round-trip fidelity across two languages is the correctness crux
(Decision 4).

**Rationale.** Established YAML libraries on each side, exercised against shared fixtures, keep the
parsers aligned.

**Status.** Accepted for the **read** path (GitKittie's `BoardStore`/`BoardMarkdown` use Yams). The
macOS app's **write** path currently bypasses Yams (hand-rolled frontmatter composition in
`AppModel`); moving writes onto Yams/`BoardMarkdown` is tracked on the board (see Decision 4).

---

### 12. iOS transport superseded: git-pont REST API, not libgit2

**Decision.** The iOS app talks to a hosted git provider's REST API through **git-pont** (no local
clone), reusing GitKittie's `RemoteBoardStore`/`BoardFileSource` for parsing. It does **not** use an
embedded `Libgit2Engine`.

**Context.** The plan originally gated iOS on an embedded-libgit2 `GitEngine`. In practice the iOS
app shipped read/write over provider APIs (GitHub + GitLab + self-hosted) with a personal-access
token, which was simpler and already works.

**Rationale.** API-first removes the native-dependency risk and reaches a working iOS board without
building/maintaining libgit2. An embedded offline mode remains a possible later addition, not a
gate.

**Status.** Accepted for iOS. The libgit2 path is **superseded / deferred**. (This is a macOS-app
doc; details live in the iOS app's `docs/`.)

---

### 13. Refused writes show under every screen, with what can be done

**Decision.** The Mac has no activity list, so a write the provider refused shows in a banner
under the detail pane (`SyncFailuresBanner`, `swift/TasksUI/SyncFailures.swift`) with Retry,
Discard and Show What It Was, instead of as a red "Not sent: …" line in `errorMessage`. How the
outbox keeps and merges writes is the iOS app's Decision 8; the code is shared.

**Status.** Accepted.

---

### 14. "Update available" from Apple's public lookup (GITKITTIE-094)

**Decision.** At launch and whenever the app comes forward, at most once a day, every GitKittie
app asks `https://itunes.apple.com/lookup?bundleId=<id>&country=<cc>` for its App Store version
(`AppStoreUpdates` in `swift/GitKittieKit`, its own product so Mail can link it without the git
engine). A newer version this device can install shows a quiet "Update available" card
(`swift/GitKittieUI/UpdateNotice.swift`) with **Update**, which opens `itms-apps://` (iOS) or
`macappstore://` (Mac), and **Not Now**, which hides that version only. In Tasks it sits where the
"New board" suggestion does: the bottom of the Mac sidebar, the home screen on iPhone and iPad.

- The Mac asks for the Mac record (`entity=desktopSoftware`): Tasks and Folder are universal
  purchases, and without it Apple answers with the iPhone version and the iOS minimum (17.0).
- The store country is the device locale's region; Apple's `Storefront` gives a three-letter code
  the lookup does not take.
- Only a copy the App Store installed asks: `AppTransaction` must be verified and from the
  production environment, so debug builds, TestFlight and local builds stay quiet.
- Offline or an unreadable answer is silent and is not counted as a check; an app not in the store
  (Mail, Bud today) gets no offer.

**Status.** Accepted.

---

### 15. Review screens: filter, notes as Markdown, lenient frontmatter (GITKITTIE-106/107/108)

**Decision.**

- **Filter.** Both apps show a request through one filter, Waiting, Answered or All, with counts
  (`ReviewFilter`, `ReviewRequest.hiddenIDs(for:)` in `swift/GitKittieKit`). It replaces "Only
  Waiting" (Mac) and "Show Answered" (iOS) and is remembered under `reviewsFilter`. What it hides
  is fixed when the request opens or the filter changes, so a file you just decided stays put.
  "Answered" means the contract's decision or answer is written (`status` not `pending`, a
  question with `answered_at`); `handled_at` does not make it wait again.
- **Pick-one groups only stay together.** Under Waiting, decided options stay on show only in a
  pick-one group that still waits. Before, any group did, so a request whose files are all
  grouped (MESSIO-008: 4 groups, 232 files) could not be filtered at all.
- **Order.** Questions first, then files group by group (`ReviewRequest.entries`), on both
  apps; Next Waiting (⌘J on the Mac, ⏩ in the iPhone header) goes on from the last thing you
  worked on.
- **Notes.** The Markdown under the frontmatter is drawn as Markdown with its pictures
  (`MarkdownBlocks` `.images`, `swift/TasksUI/ReviewNotes.swift`): folded to its start on the
  Mac when long, a Notes sheet on iPhone and iPad. The Mac used to print it as raw text.
- **Hand-written frontmatter.** When `review.md` is not valid YAML, the two slips seen in real
  requests (quotes inside a double-quoted value, `: ` inside a plain value) are mended line by
  line outside block scalars before giving up (`Review.composeLeniently`); the next reviewer
  write saves valid YAML. Anything else shows "This request can't be read" with the YAML error
  and its line, instead of an empty request.
- **Scrolling.** Cards are kept cheap to make (no AppKit checkbox, the comment field only when
  wanted, saving state read by the buttons alone), pictures are decoded off the main thread at
  the size shown and kept (`ReviewImageCache`), and the notes are a lazy stack. Measured on real
  requests: see GITKITTIE-106.

**Status.** Accepted.

---

### 16. The calendar scrolls through weeks; a change with nothing stored can only be removed (GITKITTIE-111/113)

**Decision.**

- **Calendar.** The Mac calendar is one column of weeks, five to a screen, from a year before to a
  year after today (further when a task is due further out), opening on this month
  (`BoardCalendar` in GitKanbanKit). The title names the month two weeks below the top row; the
  arrows and Today jump by month. It was one month sized to the window: with 300 tasks the
  scroll range was 0 pt, so scrolling did nothing. The 1st of a month shows the month's name and
  months alternate in shade; "N more" opens the day's tasks. The scroll position is only handed
  to the header, so scrolling redraws the title, not the weeks.
- **Unsendable changes.** A refused write whose content is not on this device (made while the
  disk was full) can never be sent. It shows Remove (no confirmation: nothing to lose) instead of
  Retry, Show and Discard, and Retry All skips it (`AppModel.unsendableSyncIDs`).

**Status.** Accepted.

---

### Open questions

- **`updated` field:** store in frontmatter or derive from `git log`? (Leaning derive-from-git.)
  **Open.**
- **Archive vs delete:** archive to an `archive/` folder or `git rm`? **Open.**
- **Background sync + conflict UI:** interval pull/push, per-board status states, and a
  conflict-resolution/recover-from-history flow are not built. **Open (tracked on the board).**
- **Mac App Store sandbox vs subprocess git:** confirm shell-out `git` is acceptable under the
  entitlements, else consider libgit2 for macOS too. **Open.**
- **Pricing / packaging:** one-time per platform vs a universal (macOS + iOS) purchase. **Open.**
- **Coexistence with GitFolder:** does GitFolder keep background-syncing a GitKanban board's folder,
  or does GitKanban own its sync entirely (avoid double-committing)? **Open.**
