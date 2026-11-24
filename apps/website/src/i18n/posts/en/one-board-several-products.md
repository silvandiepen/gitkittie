---
title: One board for several products
description: GitKittie has a website, three apps and the libraries between them. One board per product scattered the work; one board for everything buried it. Products in GitKittie Tasks give one board, a filter per product, and task numbers per product.
date: 2026-11-23
app: tasks
shot: /screenshots/tasks/mac-list-dark.webp
shotAlt: The List view of a GitKittie Tasks board on the Mac
related: markdown-kanban-in-git, one-task-one-file, agents-work-the-board
---

GitKittie is one repository with a website, three apps and the shared code between them.
I tried one board per app. Work that crossed apps — and most of it does — ended up on
whichever board I happened to have open, and I could never see the whole project in one
place.

Then I tried one board for everything. Now I could see the whole project, and nothing
else. Finding the three open tasks for the website meant reading past forty for the apps.

What I wanted was one board, and a way to look at one product on it.

## Products on a board

In a board's settings, **Products** lists what the board covers: a name for each, and
optionally a prefix — more on that below.

A task names the product it is for, in its frontmatter, like any other field:

```markdown
---
id: TASKS-014
title: Cmd-N opens a new task
product: tasks
priority: P2
---
```

In the sidebar, the board's products sit under it. Click one and the board shows that
product's tasks; click the board to see everything again. The board's filter does the
same, next to priority and assignee. A task you add while a product is selected is for
that product, so you do not have to say so twice.

![A GitKittie Tasks board on the Mac, with its lanes side by side](/screenshots/tasks/mac-board-dark.webp)

## Numbers per product

Give a product a prefix and its new tasks are numbered with it: `SITE-001`, `SITE-002`,
while the app's tasks go `TASKS-001` on. A product without a prefix uses the board's own
numbering.

It sounds cosmetic. It is not. A task id is what goes in a commit message, a branch name
and a conversation, and `SITE-012` tells you where to look before you open anything.

## Agents follow it too

Agents [working the board through Tasks](/blog/agents-work-the-board) see the same
setup. `get_board` returns the board's products with their prefixes, and a card an agent
creates for a product gets that product's prefix and next number — so an agent's
`SITE-013` sits correctly after my `SITE-012`.

## Renaming and removing

Renaming a product keeps its tasks with it: the product keeps its id, only the name
changes. Removing one leaves its tasks exactly as they are; they only lose their place in
the product list. No task file is rewritten behind your back.

---

The rest of the task format is in [the anatomy of a task file](/blog/one-task-one-file).
