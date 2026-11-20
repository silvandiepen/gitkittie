---
title: My kanban board is just markdown files in git
description: I stopped using project management tools for my own work. One task is one markdown file, the folders are the workflow, and git records everything — which turns out to matter most when coding agents are doing half the work.
date: 2026-08-14
app: gitkanban
related: one-task-one-file, git-backed-task-folder
---

I have basically stopped using traditional project management tools for my own
projects. No Jira, no Linear, no board hosted somewhere with an API I have to
sync against. My kanban board is a directory of markdown files in a git repo.

It started as a shortcut and turned into the workflow I would not give up —
especially now that coding agents do a real share of the work.

## The whole idea

One task is one `.md` file. The folders are the workflow:

```
Tasks/
  GitKit/
    1. To do/
    2. In Progress/
    3. In Review/
    4. Testing/
    5. Done/
```

Moving a task between lanes means moving a file. That is the entire mechanic.
`git mv "1. To do/GITKIT-149-quick-create.md" "2. In Progress/"` is a state
transition, and it is also a commit, with an author and a timestamp, forever.

Each file opens with a little YAML and is markdown the rest of the way down:

```markdown
---
id: GITKIT-149
status: in_progress
priority: P0
type: feature
assignee: sil
---

# AI quick-create tickets from natural language

## Context

Creating a card currently means filling out the whole form…

## Acceptance criteria

- Free-text input produces one or more properly shaped cards
- Fields are inferred from the board's own lanes, priorities and types
```

Context, scope, acceptance criteria, notes, handoff — whatever the task
actually needs. No custom field types, no admin screen, no plugin. If a task
needs a section that no other task has, you type the section.

## Why this holds up

**There is no second system.** The tasks live in the repo next to the thing
they describe. A branch that changes the code can change the task in the same
commit. Nothing has to be kept in sync, because there is only one of it.

**History comes free.** Who moved this to Done, and when? `git log`. What did
this task look like before someone rewrote the scope? `git diff`. Every
project tool builds an audit trail as a feature; git already is one.

**It is grep-able and scriptable.** Counting open P0s across eight projects is
a one-liner. Bulk-editing a field across forty tasks is `sed`. The data is
text, so every tool you already own works on it.

**It survives me.** In five years the files will still open. That is not
something I can say about a workspace on a service that may or may not still
exist.

## The part I did not expect: agents

The reason I would not go back is not the git history. It is what happened
when I started working with coding agents.

There is no integration to build. No API token, no MCP server for the tracker,
no webhook that keeps a database in step with reality. The agent reads the
same file I read, because it is a file in the repo it is already working in.

So a session can:

- read `2. In Progress/` first and find out exactly where the last one stopped
- claim a card by writing itself into `picked_up_by` and committing that
- record what it tried and rejected, in the card, as it goes
- file a new card for a problem it found but is not fixing right now
- move the file to `3. In Review/` when it is done

And git records all of it. When I come back in the morning, the board is the
report. I do not have to reconstruct what happened from a chat transcript,
because the state of the work is in the same place as the work.

The failure mode of agent-driven development is losing the thread between
sessions. A shared, plain-text, version-controlled task file is the cheapest
fix for that I have found.

## The one real problem

Markdown is great for *defining* work. A directory full of markdown files is
not great for *seeing* it.

You cannot look at forty files across five folders and get the feeling a board
gives you in one glance — what is blocked, what is piling up, what has been in
review for a week. That is genuinely what a board interface is for, and a file
listing is not a substitute.

So I built the view.

## GitKittie Tasks

[GitKittie Tasks](/gitkanban) reads the markdown and draws the board. It does
not become the source of truth — the files stay the source of truth.

- Move a card, and the markdown file moves.
- Edit the file in your editor, and the board reflects it.
- Want history? Git already has it, and the app shows you the card's own log.

No second database. No syncing two systems that will eventually disagree.
Connect it to a repo you already own — GitHub, GitLab, or a folder on your
Mac — and it renders what is there. It is a Mac and iPhone app, so the board
is wherever you are, and the files never route through a server I run.

The files are the data. Git is the backend. The board is just the view.

---

If you want the actual conventions — the frontmatter fields, how lanes get
named, how an agent claims a card without two of them grabbing the same one —
that is [the anatomy of a task file](/blog/one-task-one-file). And if you want
the folder to sync itself without you thinking about git at all, that is
[keeping a task folder in git without running git](/blog/git-backed-task-folder).
