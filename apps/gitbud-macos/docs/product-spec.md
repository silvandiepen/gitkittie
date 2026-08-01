# GitBud — Product Spec

## Name

GitBud

## One-line description

A native git client that makes history editing, rebasing, and commit repair simple and visual.

## Problem

Git is powerful, but the workflows that keep history clean are hard to trust:
interactive rebase, splitting commits, squashing, reordering, editing old messages,
and purging files from history. Existing clients expose the power, but often still
require users to understand low-level git terminology and risk.

GitBud turns those operations into visual, previewable workflows.

## Goal

Make advanced git history work feel safe and obvious.

The user should be able to:

1. Open a local repository or connect a remote repository through GitPont.
2. See branches, commits, files, diffs, and file history.
3. Select commits and merge/squash, reorder, drop, or edit them.
4. Split a commit by selecting files or hunks and moving those changes into a new commit.
5. Use AIPont BYOK Magic to draft clear commit titles and descriptions.
6. Push rewritten history only after reviewing the result and explicitly confirming.
7. Remove files from current history normally, and use a separate dangerous purge flow for
   removing files from all history.

## Product principles

- Simple language over git jargon.
- Preview before mutation.
- Safe branch/ref before rewrite.
- Force-push is explicit and uses force-with-lease.
- Local data and user credentials stay on the user's device.
- No GitBud accounts, hosted GitBud backend, or GitBud-owned sync infrastructure.
- Provider integrations are direct app-to-provider through GitPont.
- AI integrations are direct app-to-provider through AIPont BYOK.

## Primary users

- Developers who use git daily but avoid interactive rebase unless forced.
- Indie makers and small teams who want readable commit history without CLI friction.
- Agents/humans working together in repositories where cleanup before PR matters.

## Core surfaces

```txt
GitBud
├─ Repositories
│  ├─ Open Local Repository...
│  └─ Connect Remote Repository...
├─ Branch Graph
├─ Commit Inspector
├─ Diff / Hunk Selector
├─ File History
├─ Rewrite Preview
├─ Magic Commit Message
└─ Push / PR
```

## Platform model

- **macOS:** local repositories and GitPont-connected remote repositories. Remote repositories are
  cloned into app-managed checkouts for full history editing.
- **iOS/iPadOS:** remote-only through GitPont. No shell git, SSH agent, or full local clone history
  surgery in v1.

## Non-goals

- GitBud accounts.
- Hosted GitBud backend.
- GitBud-operated sync, relay, or AI infrastructure.
- Realtime collaboration.
- Windows, Linux, or web in v1.

