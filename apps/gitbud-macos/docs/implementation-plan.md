# GitBud — Implementation Plan

This plan describes the intended build order and current implementation status. The macOS
app target is scaffolded and the core v1 workflows are implemented behind real-git tests.

## Phase 0 — Foundation

- **Done:** Add XcodeGen projects for `apps/gitbud-macos` and GitBud documentation for
  `apps/gitbud-ios`.
- **Done:** Define GitKittie history models: commits, refs, graph rows, file diffs, hunks, rewrite plans, and
  rewrite results.
- **Done:** Add GitKittie shell-git commands for graph/status/diff/file-history using argv-only process calls.
- **Done:** Add Keychain-backed configuration for GitPont connections and AIPont provider keys.
- **Done:** Keep the no-backend rule in AGENTS/docs before any auth or AI code is added.

## Phase 1 — macOS repository browser and graph

- **Done:** Open local repositories from disk.
- **Done:** Connect provider accounts through GitPont and clone selected remote repos into app-managed
  checkouts.
- **Done:** Render branch graph, refs, HEAD, ahead/behind, and dirty state.
- **Done:** Show commit inspector, changed files, and diffs.
- **Done:** Show file history for selected files.

## Phase 2 — protected rewrite engine

- **Done:** Implement safety branch/ref creation.
- **Done:** Implement rewrite preview for a selected linear commit range.
- **Done:** Implement squash/merge, reorder, drop, and edit-message workflows.
- **Done:** Implement split-commit by selected files and then selected hunks.
- **Done:** Implement continue/abort state for interrupted merge/rebase/revert/cherry-pick/stash
  conflicts, with real-git AppModel tests for abort recovery across all shared conflict modes.
- **Done:** Gate force-with-lease push behind explicit confirmation.

## Phase 3 — Magic and PR workflows

- **Done:** Add AIPont BYOK provider setup.
- **Done:** Generate commit titles/descriptions from selected diffs and rewrite plans.
- **Done:** Require editable user approval before applying Magic output.
- **Done:** Use GitPont for branch metadata and PR/MR creation from rewritten or safety branches.

## Phase 4 — purge workflow

- **Done:** Add a dangerous full-history file/path purge flow.
- **Done:** Require a preview before purging.
- **Done:** Create backup refs before filtering.
- **Done:** Require separate confirmation for rewriting and for pushing rewritten refs.

## iOS/iPadOS track

- Build remote-only repository browsing through GitPont.
- Support branches, files, commits, diffs, file history where available, Magic, and branch/PR
  workflows.
- Do not block mobile on macOS rewrite engine parity.
- Do not add shell-git, SSH-agent, or local-clone assumptions to shared mobile code.
