---
title: Keeping a task folder in git without running git
description: The board only works if it is always synced. I keep one folder — conventions, task board, project notes — versioned automatically by GitKittie Folder, and symlinked into the place my coding agents already read from.
date: 2026-08-12
app: folder
related: markdown-kanban-in-git, one-task-one-file
---

[A kanban board made of markdown files](/blog/markdown-kanban-in-git) has one
obvious weak point: it is only as good as its sync. If the board on my laptop
and the board on my desktop drift apart, the whole thing stops being a source
of truth and starts being two competing opinions.

Git solves that, as long as somebody commits and pushes. Which, for a folder of
notes I edit while thinking about something else, is exactly the thing I forget
to do.

## One folder, versioned in the background

I keep a single private repo checked out at `~/Projects`:

```
~/Projects/
  Agents/          # the conventions every project and agent follows
  Tasks/           # the markdown kanban board, one folder per project
  <project>/       # plans, specs, assets — notes, not code
```

Code lives elsewhere, in `~/Repositories`. This folder is deliberately *not*
code: it is the layer above it — how I want things built, and what is currently
being built.

[GitKittie Folder](/folder) watches that folder and commits when files
change, on an interval I set once and then forget. It lives in the menu bar,
uses the git and SSH config I already have, and pushes to a repository I own.
There is no GitKittie account and no server in the middle; the files go from my
Mac to my repo.

The effect is that the board is *always* committed. Not "committed when I
remembered". Every note I scribble into a card during a call, every scope
change I type mid-thought, is in history within the interval.

## Why that matters more with agents than without

When a coding agent works a card, it does the disciplined thing — claim, commit,
push, [because the push is the lock](/blog/one-task-one-file). It is very good
at that. I am the unreliable participant. I edit a card in my editor, get
pulled into something else, and leave the change sitting in a dirty working
tree where nobody else can see it.

That is the failure that actually bites: an agent pulls, reads a card, and
works from a version of the scope I already changed twenty minutes ago on my
own machine. It is not the agent's mistake, and no amount of prompting fixes
it — the information genuinely was not there.

Automatic snapshot commits close that window. The worst case becomes a merge
conflict in a text file, which is a problem with a well-known solution, instead
of two people confidently working from different specs, which is not.

## Symlinked into where the agents already look

The second half of the setup is that this folder is not a place I go to. It is
wired into the tools directly.

My global agent instructions — the `CLAUDE.md` that every session loads — do not
contain the conventions. They contain a pointer to them:

```markdown
## Read the shared conventions

My baseline conventions for every project live in `~/Projects/Agents/`.
Start at `AGENTS.md`, then read the companion files relevant to what
you're touching.

## Track work on the shared board

`~/Projects/Tasks/` is my shared markdown kanban board.
Before starting work: pull, read `2. In Progress/`, then `1. To do/`.
```

So the chain is: agent starts → reads its global instructions → follows the
pointer into the synced folder → finds current conventions and a current board.
Every session begins from the same state, on any machine, without me pasting
context into it.

The same trick works for per-project agent files, which point at the same
folder rather than restating anything. There is one copy of the conventions.
Changing how I want commits written is a one-line edit in one file, and every
future session on every project picks it up — because that file is versioned,
synced, and read at the start of every run.

## Reading the same folder from a phone

The part I did not plan for is how often I want the board without a laptop.
GitKittie Folder opens the same repositories as plain browsable folders on
iPhone and iPad, and [GitKittie Tasks](/tasks) renders the same files as
an actual board. Same repo, same markdown, two views, no export step — because
there was never an internal format to export from.

## The shape of it

- **Notes and tasks** live in one folder, separate from code.
- **GitKittie Folder** commits and pushes it automatically.
- **Global agent instructions** point into that folder instead of copying it.
- **GitKittie Tasks** draws the board when I want to look at it.
- **Git** is the sync, the history, and the lock.

None of these pieces know about each other. They all just agree that the files
on disk are the truth — which is the only integration contract that has never
broken on me.
