# GitKanban iOS — Decisions

ADR-lite log for GitKanban iOS **as built**. Entries are **Accepted** where the app implements them,
**Open** where the plan is silent, and **Superseded** where the shipped app diverged from the
original plan (`/Users/silvandiepen/Projects/GitKittie/GitKanban/plan/`).

---

### 1. Reuse the same board logic as macOS (gitkanban-core, TS is source of truth)

**Decision:** GitKanban iOS consumes the board schema and logic from
[`@gitkittie/gitkanban-core`](../../../packages/gitkanban-core/) via the Swift mirror in
`swift/GitKittieKit` (`RemoteBoardStore`, `BoardMarkdown`, `CardText`, `BoardModel`) — it does not define
its own card/board schema.

**Context:** The board contract is platform-agnostic and already built and tested in TypeScript.
Two independent parsers would drift and render boards differently per platform.

**Rationale:** One source of truth (TS) with a Swift mirror keeps macOS and iOS byte-compatible.

**Status:** Accepted.

---

### 2. Transport is a provider REST API via git-pont, not a `GitEngine`

**Decision:** The app reads and writes the board over the host's REST API through **git-pont**
(`GitPontCore` + `GitPontGitHub`/`GitPontGitLab`), reached via `GitPontFileSource`, which conforms
to GitKittie's **`BoardFileSource`**. It does **not** call the `GitEngine` protocol.

**Context:** iOS has no shell and no `git` binary, so `ShellGitEngine` cannot run. The board layer
was made transport-agnostic (`RemoteBoardStore` + `BoardFileSource`) so a non-git transport can
back it.

**Rationale:** An API transport reaches a working read/write board without an on-device git engine.

**Status:** Accepted.

---

### 3. Embedded libgit2 (`Libgit2Engine`) — superseded

**Decision (original):** iOS would use an embedded-libgit2 `GitEngine` as its primary transport.
**Reality:** superseded — the app ships over the git-pont REST API instead; no `Libgit2Engine`
exists in the repo, and no libgit2 spike was needed to reach a working board.

**Context:** The plan named libgit2 the "real answer" with the provider API as a fallback. In
practice the API path was the faster route to read/write and became the actual (and only) transport.

**Rationale:** Removing the native-dependency and App-Store-review risk of embedded libgit2 got the
app to a working board sooner.

**Status:** Superseded. An embedded offline mode remains a possible later addition, not a gate.

---

### 4. Personal access token auth over HTTPS (multi-provider)

**Decision:** iOS authenticates with a **user-supplied personal access token**, validated via the
provider account call and stored in the iOS Keychain. Providers: GitHub, GitLab.com, self-hosted
GitLab.

**Context:** The original plan assumed reusing GitFolder's device-flow OAuth (`GitHubOAuthService`).
The shipped app uses a pasted PAT across multiple providers instead, which git-pont supports
uniformly.

**Rationale:** A PAT is the simplest cross-provider credential and avoids wiring device-flow OAuth
per provider for v1.

**Status:** Accepted (diverged from the OAuth plan). Device-flow OAuth remains possible later.

---

### 5. Bespoke iOS SwiftUI UI (not a shared macOS layer)

**Decision:** The iOS board UI (`RootView`, `BoardScreen`, `CardSheets`) is written in this app as
touch-native SwiftUI. It is **not** imported from GitKanban macOS.

**Context:** The plan hoped for one shared board UI layer across platforms. The macOS UI is
AppKit/desktop-shaped (windows, drag carousels); iOS uses lists, sheets, and swipe actions.

**Rationale:** A bespoke touch UI over the *shared model* is cleaner than conditionally sharing
desktop SwiftUI. The shared layer is the board model, not the views.

**Status:** Accepted (diverged from the shared-UI plan).

---

### 6. Writes are immediate and blind (last-writer-wins) — for now

**Decision:** Each create/edit/move/delete is an immediate single provider commit
(`commitFile`/`deleteFile` with blind overwrite), after which the board reloads.

**Context:** There is no local clone and no sync loop; the API commits directly to the branch.

**Rationale:** Immediate commits are the simplest correct behavior for a single-user board and match
the "every change is a commit" promise.

**Status:** Accepted for v1. **Conflict surfacing** (detecting a lost last-writer-wins race and
offering recovery from history) is **Open** and tracked on the board.

---

### 7. Questions in review requests

**Decision:** A review request can carry `questions:` next to (or instead of) `items:`. Each has a
question, Markdown `detail`, `options` (id, label, Markdown detail), `select: one | many` and
`other: true` for an own answer. The reviewer writes `answer` (option ids), `answer_other`,
`answered_by`, `answered_at`; the agent writes `handled_at`. Both append `comments`.

**Context:** Agents asked product decisions as files to approve, one tiny `.md` per option in a
pick-one group (GKM-001). Options showed as document icons, "pick one" was not enforced, and
approve/reject per option is the wrong interaction for a question (GKT-001).

**Rationale:** A question is answered, not judged. One choice is enforced where the answer is
written (`Review.applyAnswer`), not only in the views, and a file with two answers to a one-choice
question reads as its first. An answer can change until the agent marks it handled; after that it
is fixed, so the agent never acts on an answer that later moved under it. Bulk "approve all"
actions touch files only. The view (`swift/TasksUI/ReviewQuestionView.swift`) is shared by the
Mac and iPhone apps: on the Mac a request's questions read as a form above its files; on iPhone
and iPad each question is one page of the request's slides, questions first.

**Status:** Accepted.

---

### 8. The outbox never queues a write without its content; review writes merge

**Decision:** `Outbox.enqueue` stores a write's content before it lists the write, and throws
`OutboxError.notSaved` ("Not saved: …") when either cannot be stored; nothing is queued then. An
index that cannot be read is an error, never an empty queue. A write to a review request carries
the reviewer's `ReviewEdit`s (decision, comment, answer, question comment, each with its time) next
to the file it produced. It is sent by reading the server's copy and applying the edits again
(`Review.merge` in `GitKanbanKit/ReviewEdits.swift`), compare-and-swap through
`GitPontFileSource: VersionedBoardSource`: a comment is added when missing, a decision or answer
goes in only when newer than the server's (and an answer only while the agent has not handled it),
nothing else changes. Every queued write to one request is folded into one send, and review writes
never wait behind a refused one. A whole-file review write queued by an earlier version has its
edits read back from its copy. Card writes keep the conflict: a refused card write stays refused,
with a note that says what Retry and Discard do. Every place a refused write shows offers Retry,
Discard and Show What It Was (`swift/TasksUI/SyncFailures.swift`).

**Context:** A write made while the disk was full was listed without its content (`try?` on the
blob), so the reviewer's change was gone while the app said it was saved (ARVIK-471). Five writes
to one review request, each a whole copy from the day before, waited forever behind one refused
write, and sending any of them would have overwritten answers given since (LOBBY-001).

**Rationale:** Reviewer fields carry their own times, so edits can be applied in any order and
onto any newer copy; a base copy and a three-way diff are not needed. The merge lives in
GitKanbanKit and not in the board contract (`review.ts`): it is how this client sends, not what a
review file is. Cards have no per-field times to merge on, so their conflict stays the person's
call, made with the content in view.

**Status:** Accepted.

---

### 9. The full-screen review viewer; Changes needs a message (GITKITTIE-126/127/095)

Tapping a review picture opens a full-screen pager over the files the request screen shows, with
zoom, swipe-down to close and Approve / Changes / Reject in the thumb zone; a decision moves on to
the next waiting file with Undo. Changes is never sent without a comment, and earlier comments of
the request are offered to reuse. Rows, bars and floating controls take the theme's navy `bar`
instead of the system greys. The rules and the reasons are shared with the Mac app: see the Mac's
[Decision 19](../../gitkanban-macos/docs/Decisions.md).

**Status.** Accepted.

## Open questions

- **OAuth sign-in:** move from a pasted personal access token to provider OAuth. (Open — PAT-only
  today.)
- **Offline / local mode:** whether iOS ever gains a cached working copy or embedded git. (Open.)
- **Conflict surfacing:** review requests merge (Decision 8); cards still keep the conflict for the person to settle. (Open for cards.)
- **Per-card history:** whether to fetch it from the provider's commit API. (Open.)
- **Rank keys:** in-column reorder ships today by rewriting an integer `order` (only changed cards
  commit); adopting the core's fractional rank keys is a future refinement. (Open.)
- **Archive vs delete** and **`updated` stored vs derived** — board-wide questions iOS inherits.
  (Open.)
