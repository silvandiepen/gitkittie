---
title: The anatomy of a task file
description: What actually goes in the frontmatter, how lanes are configured per project, and the trick that lets several agents share one board without two of them grabbing the same card — the push is the lock.
date: 2026-08-13
app: gitkanban
related: markdown-kanban-in-git, git-backed-task-folder
---

[Running a board out of markdown files](/blog/markdown-kanban-in-git) only
works if the format is boring and strict. Everything below is the format I
actually use, day to day, across a dozen projects and several agents.

## The file

A card is one markdown file with a YAML header. The header is the
machine-readable part; the body is for humans and agents to read.

```markdown
---
id: GITKIT-149
title: AI quick-create tickets from natural language
project: GitKit
status: in-progress
priority: P0
type: feature
assignee: sil
picked_up_by: claude
picked_up_at: 2026-08-07T10:30:00Z
claim_expires_at: 2026-08-08T10:30:00Z
blocked: false
depends_on: []
repository: https://github.com/silvandiepen/gitkittie
working_branch: null
---

# AI quick-create tickets from natural language

## Context
## Outcome
## Scope
## Out of scope
## Acceptance criteria
## Verification
## Handoff
## Activity log
```

Two things are worth calling out.

**The ID is immutable and lives in the filename.** `GITKIT-149-quick-create.md`
keeps its name through every lane, so `git log --follow` on that path is the
task's whole life. Renaming a file to reflect a new title throws that away —
don't.

**`status` and the folder must agree.** The folder is what you see; the
frontmatter is what tools read. If they disagree, something moved a file
without updating it, and the board is lying to you. This is the one invariant
worth enforcing in a check.

## Lanes are configuration, not convention

The five lanes are a default, not a law. They are declared in the board's own
README frontmatter, which means the board configures itself in the same
plain text as everything else:

```yaml
lanes:
  - id: todo
    name: To do
    folder: "1. To do"
    status: todo
  - id: in-progress
    name: In Progress
    folder: "2. In Progress"
    status: in-progress
  - id: done
    name: Done
    folder: "5. Done"
    status: done
    terminal: true
```

A project that wants a different workflow — a sales pipeline, a content
calendar, a release train — declares its own `lanes` in its own README and
gets those folders instead. Vocabularies work the other way round: `users`,
`priorities`, `types`, `epics` and `tags` **merge** down from the root, so a
project adds a type without restating the whole list.

That split matters. Structure replaces, vocabulary extends. It is the
difference between "this project has a different workflow" and "this project
has one extra label".

Numbering the folders (`1. To do`, `2. In Progress`) is not decoration — it
makes the file listing sort into board order in Finder, in `ls`, and in every
git UI. The lane order is a property of the filesystem.

## Priorities and types, spelled out

The vocabulary is small on purpose:

| Field | Values |
| --- | --- |
| `priority` | `P0` blocker · `P1` high · `P2` normal · `P3` low |
| `type` | `fix`, `feature`, `security`, `accessibility`, `performance`, `testing`, `release`, `docs`, `chore` |
| `status` | one per lane — `todo`, `in-progress`, `in-review`, `testing`, `done` |

Four priorities, not ten. If a scheme needs a legend, nobody uses it
consistently, and inconsistent priority is worse than none.

## The part that makes it multiplayer: the push is the lock

This is the mechanic I am most attached to, because it is the one I expected
to need a server for.

Several agents and I share one board. Nothing coordinates us. So how do two
sessions avoid starting the same card at the same time?

**The successful push is the claim.** To take a card, a session:

1. pulls (fast-forward only),
2. writes `picked_up_by`, `picked_up_at`, `claim_expires_at`, and
   `status: in-progress` into the frontmatter,
3. moves the file to `2. In Progress`,
4. commits — `chore(tasks): claim GITKIT-149` — and **pushes**,
5. and only then starts the actual work.

If the push is rejected, someone else got there first. The rule is: do not
merge, do not rebase the rejected claim commit — drop it, pull, and pick a
different card. No push means no ownership.

That is optimistic concurrency, and git already implements it. There is no
lock server, no lease table, no coordination protocol to write. The remote ref
is the arbiter, because the remote ref is exactly one thing that both parties
had to agree on.

The claim carries an expiry (`claim_expires_at`, 24 hours by default) that the
active owner refreshes with a small pushed heartbeat. A session that dies
mid-task therefore releases its card on its own, and the next one can see the
lease went stale rather than guessing whether anyone is still on it.

## Writing for the next session

The body sections exist because of one recurring failure: a session ends, and
the next one — mine or an agent's — has to reverse-engineer what happened.

- **Context** says why the card exists, with evidence.
- **Scope** and **Out of scope** stop the work from quietly growing. Out of
  scope is the more useful of the two.
- **Acceptance criteria** are checkboxes with objective outcomes.
- **Verification** lists the exact commands, so "it works" is reproducible.
- **Handoff** records what is committed, what is not, and the next concrete
  step. This is the section that saves the most time.
- **Activity log** is append-only, timestamped, and boring.

The rule I hold agents to: never leave a claimed card silently stale. If you
stop for any reason, leave it describing what is committed, what isn't, and
what to do next. A card that lies about its state is worse than an empty one.

## And then you want to look at it

All of this is still a directory of text files, which is the right storage and
the wrong interface. [GitKittie Tasks](/gitkanban) reads exactly this format —
the lane config, the frontmatter, the merged vocabularies — and draws it as a
board on your Mac and iPhone. Dragging a card writes the frontmatter and moves
the file; the file stays the truth.

Next: [keeping the folder in git without running git](/blog/git-backed-task-folder),
which is how the board stays in sync across machines without me thinking about
it.
