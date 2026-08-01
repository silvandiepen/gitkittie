# GitBud (macOS) — Architecture

GitBud is a native SwiftUI app in active development on top of shared GitKit history
services, GitPont-style direct provider integration, and AIPont-style Magic. The app is a thin UI
and state layer; git operations belong in `swift/GitKit`.

## Layering

```txt
SwiftUI views
  History (commit graph + detail) · Changes (working copy) · Branches · Pull Requests · Settings window
        │
  GitBudActions — every git verb declared once, rendered as context menus,
                  the detail toolbar, and the ⌘K palette
        │
        ▼
GitBudCore
  AppModel (@Observable, @MainActor)
  session, selected repo/ref/commits/hunks, rewrite plan, Magic state, operation progress
        │
        ├── GitBud services (UI-agnostic orchestration)
        │     RepositorySessionStore · RewriteCoordinator · MagicCoordinator
        │
        ├── swift/GitKit
        │     graph · refs · branch switching · status · stage/unstage · diff · file history · rewrite · purge · safety checks
        │
        ├── GitPont
        │     provider auth · repo listing · remote metadata · HTTPS git credentials · PR/MR
        │
        └── AIPont
              BYOK provider selection · commit-message suggestions
```

Views call `AppModel` intents only. They do not shell out to git, call provider
APIs directly, or hold credentials.

`GitBudCore` is a macOS framework target that currently contains the testable app
model and settings store. The app target composes SwiftUI views around that state
surface, and `GitBudTests` runs real-git logic tests against `GitBudCore` without
launching the GUI app.

## View layout

Views live one concern per file under `GitBud/Views/`, and `GitBud/Core/` holds
everything the `GitBudCore` framework target compiles:

```txt
Core/           AppModel · GitBudSettingsStore            (framework target)
Views/Shell/    ContentView · Sidebar · RepositoryToolbar · NoRepositoryView
Views/History/  HistoryView · CommitGraphCanvas · CommitRow · CommitDetailView · FileList
Views/Changes/  ChangesView · WorkingCopyList · StashSection
Views/Branches/ BranchesView · BranchRow · TagSection
Views/PullRequests/ PullRequestsView · PullRequestReviewView
Views/Settings/ SettingsScene (Accounts · Magic · Safety · Repository tabs)
Views/Actions/  GitBudAction · GitBudActions · ActionSheet · CommandPalette
Views/Common/   GitBudTheme (+ panelCard/gitBudPanelRow) · DiffView · ConflictPanel
```

`project.yml` points the `GitBudCore` target at the `GitBud/Core` directory and
excludes it from the app target, so adding a file to either side needs no project
edit beyond regenerating with `npm run gitbud:generate`.

## Selection model

One ordered `selectedCommitIDs` (graph order, newest first) is the working set for
multi-commit operations, and `focusedCommitID` is the commit whose detail is shown.
These replaced three overlapping properties — `selectedCommitID`, a
`rewriteSelection` set, and a parallel `rewriteOrderNewestFirst` array — that all
described "which commits am I working on". Reordering mutates `selectedCommitIDs`
in place; `applyPlannedCommitOrder` hands that order to `GitHistory.reorderCommits`.

## Commit graph

`GitHistory.commitGraph` returns a window of history (`historyLimit`, raised by
`loadMoreHistory()`). `layoutCommitGraph` in GitKit assigns each commit a lane and
colour and emits the edges crossing each row; lanes are reused when free but never
re-indexed, so pass-through lines stay vertical. `CommitGraphCell` draws one row's
band at a time, which keeps the list lazy — there is no scroll-offset synchronisation
between the list and a full-height canvas.

## Repository modes

### Local repository mode

The user opens an existing local repository. GitBud stores a security-scoped
bookmark to the selected folder, reads graph/status through GitKit, and performs
history edits with macOS system git behind GitKit APIs.

### GitPont remote mode

The user can paste a remote URL directly or load provider repositories with a
user-supplied provider token or connect through GitHub device-flow OAuth, save
the provider token in local Keychain, pick a repository, and clone it into
app-managed storage. Full history editing then uses the same local rewrite
engine as local repository mode. GitPont is the provider boundary for identity,
repository metadata, HTTPS git credential context, remote branches, and PR/MR
workflows.

Open PR listing, selected PR review summaries, inline review comments, inline
comment replies, overall review submission, and draft PR creation are implemented
as direct app-to-provider requests using the user-supplied provider token and the
selected provider repository. GitBud reads open PR metadata, fetches selected PR
detail/review counts and changed-file metadata, and sends review/PR actions
directly to the provider API; no GitBud account, relay, hosted backend, or stored
server-side credential is involved.

Remote-only API editing is not the macOS v1 path for rebase/split/squash because
those operations need complete git object/history semantics. GitPont API writes
can still support metadata and simpler provider-native operations.

## Shared GitKit work

GitBud needs GitKit APIs beyond the current `GitEngine` surface:

- Graph: commits, parents, branch/ref decoration, ahead/behind, merge-base, branch-flow
  current-only/target-only commit summaries, and current-vs-target branch file impact.
- Search: commit-message search and changed-content pickaxe search backed by git log so
  matching commits can reuse the normal inspector, diff, file history, and rewrite selection
  surfaces.
- Branches: local/remote branch listing, upstream hints, clean-tree branch switching,
  remote branch checkout as a local tracking branch, branch creation from a selected
  commit, linked worktree list/create/remove for branch checkouts, local branch
  rename/delete, fetch/prune, current-branch push with upstream setup, pull-rebase
  from `origin`, local branch merge, and current-branch rebase onto a selected branch.
- Submodules: recursive submodule status plus selected/all update-init actions for
  repositories that vendor or pin nested git projects.
- Remotes: configured remote list/add/remove backed by git config, plus provider-backed
  repository listing and app-managed clone onboarding.
- Tags: local tag listing, selected-commit tag creation, and safe selected tag deletion.
- Status: clean/dirty tree, staged/unstaged/untracked files, conflicts, selected path
  stage/unstage/commit/amend operations, and discard that restores tracked paths or cleans
  selected untracked paths. Stash operations list stashes, save all dirty/untracked
  work or only selected paths, apply or pop a selected stash onto a clean tree,
  create a branch from a selected stash, surface stash-pop conflicts through the
  shared conflict model, and drop a selected stash.
- Diff: commit/file/hunk diffs, patch application, selected-file extraction, and selected-hunk
  extraction from older commits, plus selected file restore from a chosen commit into the
  working tree.
- File history and blame: commits that touched a file, following renames when possible,
  plus line-level blame for the selected file in the current tree.
- Rewrite: safety branch/ref, squash, reorder, selected-commit file/hunk split,
  selected-path HEAD amend, edit message, drop, mixed reset to selected commit
  with a backup ref, reflog recovery to a selected branch position with a backup
  ref, revert as a new inverse commit, cherry-pick selected commits, continue,
  abort, rewritten-stack preview.
- Push safety: upstream state, normal push/upstream setup, force-with-lease readiness,
  protected branch policy hooks.
- Purge: full-history path filtering, affected commit/branch/tag preview, repository-size
  estimate, backup refs, and explicit failure states.

## Rewrite flow

1. Validate that the working tree is clean and the selected commits form a
   rewriteable range.
2. Create a safety branch/ref before mutating history.
3. Build a rewrite plan from selected commits, files, and hunks.
4. Preview the resulting stack and affected files.
5. Apply the rewrite through GitKit.
6. If conflicts occur, show affected commits/files and offer side-aware or manually
   edited resolution plus continue/abort for the active merge or rebase. Conflict UI
   labels must use `Your change` and `REmote change`.
7. After success, show local branch state and require the exact
   `FORCE PUSH <branch>` confirmation phrase for force-with-lease push.

Direct rewritten-history push is additionally gated by local protected-branch
policy. By default, `main`, `master`, `development`, and `release/*` are treated
as protected: GitBud still allows local review/rewrite with safety refs, but the
force-with-lease button is disabled and the user is pointed toward a branch plus
draft PR workflow. The protected branch patterns are editable in the app and are
persisted locally through `GitBudSettingsStore`; they are not synced through a
GitBud account or backend.

## Magic flow

1. User selects a commit, rewrite plan, or selected diff.
2. `MagicCoordinator` builds an AIPont request from the diff and local context.
3. AIPont sends the request to the user's selected BYOK provider.
4. GitBud displays the suggestion as editable text.
5. User explicitly applies or discards it.

Magic stores non-secret provider defaults in local app preferences and stores the
provider API key through `KeychainService`. Prompts and responses should not be
written to repo config or logs by default.

## Test flow

`npm run gitbud:test` builds the GitBud scheme for testing and runs the generated
`GitBudTests.xctest` bundle directly with `xcrun xctest`. This avoids macOS app
test-host launch flakiness while still exercising the same `GitBudCore` state and
GitKit rewrite code that the app uses.

## iOS/iPad relationship

iOS and iPadOS GitBud are remote-only through GitPont. Shared UI concepts can be
ported, but shared services must not assume subprocess git, SSH agent access, or
local clones are available on those platforms. iOS/iPad workflows should focus on
remote repository browsing, file history, diffs, commit-message Magic, branch/PR
creation, and provider-supported safe edits.
