---
title: Letting coding agents work the board, through the app
description: How I hand a project to Claude Code or Codex without losing the thread. The agent reads the board, claims a card, writes down what it tried, and leaves the card saying where it stopped — through GitKittie Tasks, with no copy of the repository.
date: 2026-11-23
app: tasks
shot: /screenshots/tasks/mac-board-dark.webp
shotAlt: A GitKittie Tasks board on the Mac, with To do, In Progress and Done
related: markdown-kanban-in-git, one-task-one-file, from-task-to-pull-request
---

The hard part of working with coding agents is not the code. It is the gap between
sessions. An agent finishes, the context is gone, and the next one starts by guessing
what the last one did.

My fix is boring on purpose: the agent keeps the board. Every session starts by reading
it and ends by updating it. In GitKittie Tasks that goes through the app, so the agent
needs nothing but a connection.

## Turning it on

On the Mac, open Tasks, then the account menu, then **Agent Access…**. It shows one
command to run once in a terminal. After that, Claude Code can reach your boards — and it
opens Tasks by itself when the app is closed. Other agents use the same command as a
stdio MCP server, or an HTTP address with a header while Tasks is open.

What the agent gets is the boards in your sidebar. It does not need the repository on
disk: Tasks fetches what it asks for and commits its changes straight to the repository,
like any change you make on the board.

## What a session looks like

I put the same short contract in every project's instructions, and the tools are shaped
around it.

**Start where the last one stopped.** The first call is `list_cards` on lane
`in-progress`. If a card is there, that is the work. Then lane `todo`, for the queue.
`get_board_rules` returns everything written down about the board — the repository's
`AGENTS.md`, the card template, the board's own rules — so the agent reads the contract
once before it changes anything.

**Claim before building.** `claim_card` records the agent as the owner with a lease and
moves the card to In Progress. When another session already holds an unexpired claim,
the call is refused. Two agents on one board never both pick up the same card.

**Write it down while it happens.** `update_card` changes fields, replaces the body,
moves the card, and appends to the activity log. The rule I give agents: record scope
changes and approaches you tried and rejected *as you go*, not as a summary at the end.
A rejected approach written down saves the next session from trying it again.

**File what you find.** A real problem that is out of scope becomes its own card with
`create_card`, which takes the board's template and the next free id. It does not get
fixed on the side, and it does not get forgotten.

**Never leave a claim silently stale.** If the session ends — done, blocked, out of
context — the card says what is committed, what is not, and the next concrete step.

![A task open in its own window in GitKittie Tasks, with its details, activity and notes](/screenshots/tasks/mac-task-dark.webp)

## Why the board and not a chat log

When I come back, I read the board, not a transcript. In Progress shows what is
running. A card's activity log shows what was tried. And because every change is a
commit, `git log` on the board folder is an exact record of who moved what, and when,
agent or not.

It also means the agent works within the board's rules rather than its own idea of
them. Lanes, priorities, types and the card id prefix come from the board, and
`get_board` returns them. A card an agent makes looks like a card I make.

## Docs and attachments come with it

Boards can keep their own documentation — specs, decisions, notes — and agents can use
it: `list_docs`, `search_docs` and `get_doc` to read, `write_doc` to add a page.
Replacing a page needs the exact text the agent read, so it cannot overwrite a change I
made in the meantime. `attach_file` puts a screenshot on a card.

And when an agent makes something a person has to judge — an image, a model, audio — it
does not decide alone. That is [the review loop](/blog/reviewing-agent-work-from-your-phone).

---

The format underneath all of this is the one in
[the anatomy of a task file](/blog/one-task-one-file). For how the pieces fit in a whole
project, see [from a task to a pull request](/blog/from-task-to-pull-request).
