# GitBud (macOS) — Features

GitBud is a native macOS git client for people who want to understand and repair
history without living in git terminology. It visualizes branches, commits, file
history, and rewrite previews, then turns advanced operations into explicit,
reviewable workflows.

## Status legend

| Mark | Meaning |
|---|---|
| **Implemented** | Built in the macOS app or shared GitKit layer and covered by tests. |
| **Planned** | Product/architecture plan; not implemented yet. |
| **Future** | Intentionally deferred until the core workflow proves itself. |

Anything not explicitly marked **Implemented** remains planned or future work.

## Surfaces

GitBud has four places you can navigate to. Everything else is either a verb on a
selected item or a preference.

| Surface | Shortcut | Holds |
|---|---|---|
| History | ⌘1 | The multi-lane commit graph, search, and the detail pane for the selected commit (message, files, diff, blame, file history). |
| Changes | ⌘2 | The working copy: file selection, commit box, amend, Magic message drafting, and stashes. |
| Branches | ⌘3 | Local and remote branches, most recently updated first, plus tags. |
| Pull Requests | ⌘4 | Provider PR list, review summary, per-file patches, inline comment threads, and review submission. |
| Settings | ⌘, | Accounts, Magic (BYOK), Safety (protected branches), and Repository (remotes, linked worktrees, submodules). |

Verbs reach the user three ways, all rendered from one registry (`GitBudActions`):
right-click the item, the small toolbar in the commit detail pane, or the ⌘K
command palette, which lists what applies to the current selection.

## Repository sources

| Capability | Status | Notes |
|---|---|---|
| Open local repository | Implemented | User selects an existing local git repo. Graph, diffs, file history, branch state, and conflicts load from real git. |
| Connect provider account | Implemented | Token-backed provider repository listing is implemented through the GitPont/GitHub-style repo service. GitHub device-flow OAuth connects directly from the app to the provider and saves the token in local Keychain; pasted provider tokens can also be saved or cleared locally. No GitBud account or hosted backend is involved. |
| Open remote repository | Implemented | Remote URLs and selected provider repositories clone into app-managed checkouts for full macOS history editing. |
| Remote metadata | Implemented | Local upstream/ahead/behind, configured remote list/add/remove, fetch/prune, current-branch push with upstream setup, pull-rebase, remote branch refresh, provider repo listing, open provider PR listing, selected PR review summaries with changed files and inline comments, new inline review comments, inline comment replies, overall PR review submission, draft PR creation, and force-with-lease readiness are implemented. |
| iOS/iPad parity | Future | Remote-only through GitPont, not local shell git. |

## Visual git model

- **Implemented:** Multi-lane commit graph drawn from real parent links — branches occupy their
  own coloured lane, merges are ringed and fan out to each parent, and branch points show the
  child lanes converging. Lane assignment lives in `GitKit/CommitGraphLayout.swift` and is unit
  tested (linear, branch/merge, octopus, orphan root, parent outside the fetched window).
- **Implemented:** History loads in windows and fetches older commits on demand rather than
  silently stopping at a fixed count.
- **Implemented:** Commit graph with local branches, remote branches, HEAD, upstream/ahead/behind
  state, and the selected rewrite range shown as a numbered plan in the detail pane.
- **Implemented:** Fetch/prune `origin` and refresh remote branch decorations.
- **Implemented:** List configured remotes, add a remote, and remove a selected remote.
- **Implemented:** Push the current branch, setting `origin/<branch>` as upstream when needed.
- **Implemented:** Pull the current branch with rebase and surface remote sync conflicts.
- **Implemented:** Branch list with current branch, local/remote labels, upstream hints, and
  tested local branch switching.
- **Implemented:** Linked git worktree list/create/remove so users can spin out a separate
  checkout for branch work without leaving GitBud.
- **Implemented:** Submodule list and update/init actions for repositories that depend on
  nested git projects.
- **Implemented:** Check out a remote branch by creating and switching to a local tracking branch.
- **Implemented:** Create a new branch from the selected commit and switch to it.
- **Implemented:** Rename and safely delete selected non-current local branches.
- **Implemented:** List local tags, create a tag on the selected commit, and delete a selected tag.
- **Implemented:** Merge a selected local branch into the current branch.
- **Implemented:** Rebase the current branch onto a selected local branch and surface conflicts.
- **Implemented:** Branch flow view that explains the merge-base, current-only commits, and
  target-only commits before a merge or rebase, plus the files that differ between the
  current branch and selected target branch.
- **Implemented:** Commit inspector with message, author, touched files, and diff.
- **Implemented:** Search history by commit message text or by changed content so matching
  commits can be selected and inspected through the normal diff flow.
- **Implemented:** File browser with per-file history: show the commits that changed a selected
  file, following renames where git can.
- **Implemented:** Restore the selected file from the selected commit into the working tree for
  review before committing or amending.
- **Implemented:** Line-level blame for the selected file, showing commit, author, summary,
  line number, and content.
- **Implemented:** Working tree panel with staged/unstaged/untracked status, path selection,
  stage, unstage, selected-path commit, selected-path amend into HEAD, and discard for
  tracked or untracked file changes.
- **Implemented:** Stash panel actions: list stashes, save all dirty work including untracked
  files, save selected paths only, apply or pop a selected stash onto a clean tree, and
  create a new branch from a selected stash or drop the selected stash.

## History editing

GitBud's core workflow is protected interactive rebase without exposing the user
to an editor todo file.

- **Implemented:** Select multiple commits and merge/squash them into one.
- **Implemented:** Reorder selected commits through explicit reverse-order replay.
- **Implemented:** Edit the HEAD commit title/body.
- **Implemented:** Amend HEAD with selected working-tree paths while leaving unrelated dirty
  paths out of the amended commit.
- **Implemented:** Drop a selected commit.
- **Implemented:** Reset the current branch to a selected commit with an automatic safety
  branch and mixed-reset worktree preservation for review.
- **Implemented:** Inspect recent reflog branch positions and recover the current branch
  to a selected entry with an automatic safety branch for the pre-recovery tip.
- **Implemented:** Revert a selected commit by creating a new inverse commit, including
  conflict resolution with the same `Your change` / `REmote change` flow.
- **Implemented:** Cherry-pick a selected commit onto the current branch, including
  conflict resolution with the same `Your change` / `REmote change` flow.
- **Implemented:** Select a commit, then select files or hunks inside it, and move those
  changes into a new commit while removing them from the original commit and replaying later
  commits.
- **Implemented:** Preview the rewritten stack before applying planned reorder operations.
- **Implemented:** Continue or abort interrupted merge, rebase, revert, cherry-pick, and stash-pop workflows.

## Magic

Magic uses AIPont with bring-your-own-key provider credentials.

- **Implemented:** Suggest commit titles and descriptions from selected diffs through direct BYOK provider calls.
- **Implemented:** Suggest a better message for a selected commit.
- **Implemented:** Suggest a clean reviewed message for split and squash rewrite operations.
- **Implemented:** Let the user review the suggestion before applying it.
- **Implemented:** Never apply AI output automatically.
- **Implemented:** Persist non-secret Magic settings locally and store the API key through Keychain.

## Safety

- **Implemented:** Surface dirty working tree state before rewrite actions.
- **Implemented:** Require a clean working tree before history rewrites.
- **Implemented:** Create a safety branch/ref before rewriting — automatically, on every
  rewrite, rather than as a button the user has to remember.
- **Implemented:** Offer a one-click undo after a rewrite, resetting the branch back to the
  safety ref that was cut beforehand.
- **Implemented:** Push rewritten history only through an explicit action with a typed
  confirmation.
- **Implemented:** Use force-with-lease for rewritten branch pushes.
- **Implemented:** Require the exact `FORCE PUSH <branch>` confirmation phrase before
  publishing rewritten history.
- **Implemented:** Treat `main`, `master`, `development`, and `release/*` as protected
  by default for direct rewritten-history pushes.
- **Implemented:** Let users edit and persist protected-branch patterns locally.
- **Implemented:** List open provider pull requests directly from the selected provider
  repository using the user-supplied token.
- **Implemented:** Create a draft provider PR directly from the selected provider repository
  and current branch after local review.
- **Implemented:** Load selected provider PR review summaries directly from the provider:
  changed files, commit count, additions/deletions, issue/review comments, mergeability,
  approvals, requested changes, per-file status/line counts, and provider patch previews
  for selected changed files.
- **Implemented:** Load provider inline review comments for the selected PR and show the
  comments attached to the selected changed file.
- **Implemented:** Reply to a selected provider inline review comment directly from GitBud
  using the user-supplied provider token.
- **Implemented:** Create new provider inline review comments on the selected pull request
  file and changed-file line directly from GitBud using the user-supplied provider token.
- **Implemented:** Submit overall provider PR reviews directly from GitBud: approve,
  comment, or request changes with a review body.
- **Implemented:** Explain conflicts with affected files and provide `Use Your change`,
  `Use REmote change`, editable manual resolution, and mode-specific continue/abort actions.
- **Implemented:** Surface stash-pop conflicts through the same `Your change` /
  `REmote change` conflict UI, with finish and abort actions.

## File deletion and purge

Normal delete removes a file from the current tree and creates a commit.

Full-history purge is separate and dangerous:

- **Implemented:** Select a file path to remove from the current branch history.
- **Implemented:** Show affected commits, branches/tags, and repository-size impact where available.
- **Implemented:** Create backup refs before filtering.
- **Implemented:** Require the exact `PURGE <path>` confirmation phrase before rewriting history.
- **Implemented:** Require separate explicit action before pushing rewritten refs.

## Non-goals for v1

- Realtime collaboration.
- Remote-only full history rewriting on macOS; v1 uses app-managed local
  checkouts for full rewrite operations.
- Shell git, SSH agent, or local-clone workflows on iOS/iPad.
- Windows, Linux, or web.

## Permanent non-goals

- GitBud accounts.
- A hosted GitBud backend.
- GitBud-owned sync infrastructure.
- Relaying repositories, diffs, commits, provider tokens, or AI provider keys
  through infrastructure operated for GitBud.
