# GitBud (macOS) — Decisions

An ADR-lite log for GitBud. Entries are planned unless later updated with an
implementation status.

---

### 1. GitBud lives inside the GitKit monorepo

**Decision.** GitBud is a third GitKit product, alongside GitFolder and
GitKanban.

**Context.** It needs the same native foundations: git process execution,
Keychain storage, provider integration, and app services.

**Rationale.** Shared git correctness belongs in `swift/GitKit`; apps depend on
packages, never each other.

**Status.** Accepted.

---

### 2. V1 is rebase-first, not generic-client-first

**Decision.** GitBud should eventually feel like a simple Tower-style git client,
but v1 focuses on visual history editing: split, squash/merge, reorder, drop,
message edit, file history, and safe purge.

**Context.** Broad git-client parity would dilute the differentiator.

**Rationale.** Rebasing and commit repair are high-friction workflows where a
native visual app can provide the most value.

**Status.** Accepted.

---

### 3. macOS supports local repos and GitPont remotes

**Decision.** macOS supports opening local repositories and connecting remote
repositories through GitPont. GitPont-selected remotes are cloned into
app-managed checkouts for full history editing.

**Context.** Full rebase/split/squash requires complete local git object
semantics. Provider APIs are useful for auth, repo listing, metadata, and PR/MR
flows, but not the primary v1 engine for history surgery.

**Rationale.** This gives a simple remote onboarding path without weakening the
rewrite model.

**Status.** Accepted.

---

### 4. iOS and iPadOS are remote-only through GitPont

**Decision.** iOS and iPadOS GitBud do not use shell git, SSH agent workflows, or
full local clone history surgery. They work against remote repositories through
GitPont.

**Context.** Apple mobile platforms do not provide the same system git process
model as macOS, and maintaining a full embedded git stack is a separate product
risk.

**Rationale.** GitPont gives provider-neutral remote access and keeps mobile
scope realistic.

**Status.** Accepted.

---

### 5. History rewrites are protected by default

**Decision.** Rewrites require a clean working tree, create a safety branch/ref,
show a preview, and require the exact `FORCE PUSH <branch>` confirmation phrase
before force-with-lease push.

**Context.** Split/squash/reorder/drop/purge can destroy work if treated as
ordinary edits.

**Rationale.** The app should make dangerous operations understandable and
recoverable.

**Status.** Accepted.

---

### 6. Magic uses AIPont BYOK

**Decision.** AI-assisted commit messages use AIPont with bring-your-own-key
provider credentials.

**Context.** GitBud should support many AI providers without owning a hosted AI
backend or storing provider keys outside the user's machine.

**Rationale.** AIPont keeps Magic provider-neutral and user-controlled.

**Status.** Accepted.

---

### 7. Full-history file purge is separate from normal delete

**Decision.** Deleting a file from the current tree is a normal commit. Removing
files from all repo history is a separate dangerous workflow with backup refs and
an exact `PURGE <path>` confirmation phrase.

**Context.** Users may need to remove generated files, large binaries, or secrets
from the repository entirely.

**Rationale.** Purge is useful but has a larger blast radius than ordinary commit
editing.

**Status.** Accepted.

---

### 8. No GitBud backend or accounts

**Decision.** GitBud must work by itself. There is no GitBud account system,
hosted GitBud backend, GitBud sync service, or GitBud-operated relay for
repositories, diffs, commits, provider tokens, or AI keys.

**Context.** GitBud can integrate with user-selected git hosts through GitPont
and user-selected AI providers through AIPont BYOK, but those are client-side
integration boundaries, not a product backend.

**Rationale.** The product should stay own-your-data, no-server, and simple to
trust.

**Status.** Accepted.

---

### 9. Conflict resolution uses explicit side labels and editable output

**Decision.** Conflict panels use the labels `Your change` and `REmote change`,
and users can resolve by choosing either side or by editing the final resolved
file contents.

**Context.** Rebase and merge conflicts are central to GitBud's history-editing
workflow. Side labels need to be plain and stable across the app and tests, and
some conflicts need a real manual merge instead of a whole-side choice.

**Rationale.** The app should make conflict resolution understandable while still
landing real git state: write the resolved file, stage it, then let the active
merge or rebase continue through GitKit.

**Status.** Accepted and implemented.

### 10. Four surfaces; everything else is an action or a preference

**Decision.** The app has four navigable surfaces — History (the commit graph),
Changes (the working copy), Branches, and Pull Requests. The former Overview,
Working Tree, Rewrite, and Settings sidebar entries are gone. Overview and History
were the same commit list, so they merged into History; Rewrite became verbs on
selected commits; Settings became a real macOS Settings window on ⌘,.

**Context.** The previous UI carried seven sidebar entries and a permanent
inspector column of mostly-disabled buttons. `WorkspaceView.swift` had grown to
3,815 lines, roughly 1,400 of which were unreachable — seven `Legacy*Workspace`
views and a 1,090-line `RewritePanel` that nothing rendered. Real features
(submodules, linked worktrees, reflog recovery, PR review submission) were only
reachable from that dead panel, so they were effectively unavailable.

**Rationale.** A place you navigate to should hold information. A verb should hang
off the thing it acts on. Splitting the two removes the button walls without
removing capability: every operation that lived in the dead panel was re-homed
(sync verbs to the window toolbar; remotes, worktrees, and submodules to Settings →
Repository; purge to the file context menu; reflog recovery to the undo banner).

**Status.** Accepted and implemented.

### 11. Actions are declared once and rendered three ways

**Decision.** Every git verb is declared in `GitBudActions` as a `GitBudAction`
value carrying its title, icon, enablement, the reason it is unavailable, and the
interaction it needs (immediate, input, confirm, or typed confirmation). Context
menus, the commit detail toolbar, and the ⌘K palette are three renderers over that
one registry.

**Context.** The old UI declared the same verb in several places with subtly
different enablement conditions, which is how the tag section ended up visible
only while the working tree was dirty and disabled in exactly that state.

**Rationale.** One declaration means one enablement rule and one place to add a
verb. Carrying `disabledReason` also lets the UI explain itself rather than
silently greying out.

**Status.** Accepted and implemented.

### 12. The safety branch is automatic, and undo is one click

**Decision.** GitBud cuts a safety branch before every rewrite without being
asked, and surfaces a one-line undo banner afterwards that resets the branch back
to that ref. The manual "Create Safety Branch" button is gone.

**Context.** `runRewrite` already created a safety branch when none existed, so
the button was a redundant instruction to do something the app did anyway.

**Rationale.** Safety that depends on the user remembering to press a button is
not safety. Making it automatic and pairing it with a visible way back is what
makes destructive verbs safe to offer directly in a context menu. Force-pushing
rewritten history keeps its typed confirmation and `--force-with-lease`; nothing
about the publish path was loosened.

**Status.** Accepted and implemented.

### 13. The commit graph is laid out in GitKit, not in the view

**Decision.** `layoutCommitGraph` in `swift/GitKit/Sources/GitKit/CommitGraphLayout.swift`
turns the newest-first `[GitCommitNode]` into `[GitGraphRow]` — lane, colour, and the
edges crossing each row. The SwiftUI `Canvas` only draws what it is given.

**Context.** The old commit list drew a single straight vertical line per row even
though `parentIDs` had been parsed all along, so branches and merges were invisible.

**Rationale.** Lane assignment is pure logic over values, so it belongs where it can
be unit-tested without a UI — including the cases that are awkward to reproduce by
hand: octopus merges, orphan roots, and parents that fall outside the fetched window.

**Status.** Accepted and implemented.
