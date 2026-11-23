---
title: Reviewing what an agent made, from your phone
description: An agent can write code on its own, but it should not decide whether an icon, a 3D model or a sound is good enough. In GitKittie Tasks it asks, you answer on your phone, and it picks up your decision and carries on.
date: 2026-11-23
app: tasks
shot: /screenshots/tasks/iphone-board-dark.webp
shotAlt: A GitKittie Tasks board on iPhone, with lanes folded into sections
related: agents-work-the-board, screenshot-to-task, from-task-to-pull-request
---

Code has tests. A generated app icon does not. Neither does a 3D model, a voice line or
a short video. An agent can make twenty of them in an afternoon, and somebody still has
to say which ones are right.

That somebody is me, and I am usually not at my desk. So the review happens on the
phone, and the agent waits for it.

## How the agent asks

An agent connected through [Agent Access](/blog/agents-work-the-board) calls
`create_review` with the files and a title. Tasks writes the files and the request into
the board's repository, next to the cards. A redo of something I rejected is added to
the same request, marked as the revision of the item it replaces, so I see the history
instead of a fresh pile.

Big files can be committed in the board's repository under its `review` folder instead
of being sent through the call.

## How I answer

**Reviews** in the sidebar lists every open request across all my boards. On the Mac it
is a list. On iPhone and iPad it goes one item per screen: look, then approve, reject,
or ask for changes, with a comment. On an image I can draw on the part I mean, which
beats describing "the left ear, a bit lower" in words.

Notifications are a switch: I get told when a review is waiting, and the app icon shows
how many are.

## How the agent carries on

The agent does not poll a chat. It calls `wait_for_reviews`, which returns as soon as I
have decided something it has not acted on yet — or comes back empty when the time is up,
so it can call again. `list_reviews` shows the same, with `to_handle` as the default.

For each decision it does the obvious thing: ship the approved file, drop the rejected
one, make the redo. Then it calls `handle_review_item` to record that. When a request has
nothing left waiting and nothing left to handle, it is finished and its folder is
removed. `close_review` cleans up the rest, and refuses while anything is still waiting
on me.

## Why it lives on the board

Because the request is files in the repository, it has the same properties as the cards.
It is in git, with history. It survives the agent's session ending, and mine. And the
next session finds it: whatever I decided overnight is waiting in `to_handle` when the
agent starts in the morning.

I have run asset-heavy projects this way: dozens of generated models, each reviewed on
the phone between other things, with the agent redoing what I sent back. The bottleneck
used to be me finding time at a desk. Now it is just me.

---

Bugs go the other way: I find them on the phone and hand them to the board. That is
[from a screenshot to a task](/blog/screenshot-to-task).
