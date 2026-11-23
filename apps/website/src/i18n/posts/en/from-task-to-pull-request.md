---
title: From a task to a pull request, with all three apps
description: How the GitKittie apps fit together on a real day. Folder keeps the project's rules versioned, Tasks holds the work and lets agents pick it up, and Bud turns what they wrote into commits worth reviewing.
date: 2026-11-23
shot: /screenshots/tasks/ipad-board-dark.webp
shotAlt: A GitKittie Tasks board on iPad
related: agents-work-the-board, take-back-part-of-a-commit, git-backed-task-folder
---

*GitKittie Folder and GitKittie Tasks are on the App Store. GitKittie Bud is not yet; it
is under test against real repositories.*

Each GitKittie app does one thing. On their own pages they read like three products. In
practice they are three steps of one loop, and the thing they have in common is that each
step leaves its result in git, where the next one can find it.

Here is that loop on an ordinary day.

## 1. The rules live in a folder that versions itself

Every project has instructions for whoever works on it — me in six months, or an agent
right now: conventions, how to commit, how to use the board. They are plain Markdown
files in one folder.

[GitKittie Folder](/folder) watches that folder and commits it to my own repository on an
interval, so the rules are versioned without me thinking about git. The details are in
[keeping a task folder in git without running git](/blog/git-backed-task-folder).

## 2. The work lives on the board

A [GitKittie Tasks](/tasks) board is a folder of Markdown files in the project's
repository: one file per task, one folder per lane. I file tasks from the Mac, from the
phone, or [from a screenshot in the share sheet](/blog/screenshot-to-task).

![A GitKittie Tasks board on the Mac](/screenshots/tasks/mac-board-dark.webp)

## 3. An agent picks it up

With Agent Access on, a coding agent reads the board through the app: In Progress first,
then the queue. It claims a task, works, and writes down what it tried as it goes. If it
stops, the task says where and why. That is
[letting coding agents work the board](/blog/agents-work-the-board).

When the agent makes something only a person can judge — an image, a model, a sound — it
asks for a review, and I answer on the phone. See
[reviewing what an agent made](/blog/reviewing-agent-work-from-your-phone).

## 4. The commits get cleaned up

Agents commit honestly but not tidily. One commit fixes the bug, renames a view and
adjusts some spacing on the way.

In [GitKittie Bud](/bud) I read the branch's history, open the commit that did too much,
and [split it](/blog/split-a-commit-with-apple-intelligence) — with a suggestion from the
on-device model, a safety branch first and an Undo after. A stray line that should not be
there at all I [take back](/blog/take-back-part-of-a-commit) on its own, without
reverting the rest.

![A commit open in GitKittie Bud's commit window, with lines chosen](/screenshots/bud/mac-chosen.webp)

## 5. Review, and the board catches up

The branch goes up as a pull request with commits that each say one thing. On the
phone, Bud can [turn a single bad line into its own pull request](/blog/undo-a-line-from-your-phone)
if I spot one late.

The task moves to review, then done. Its file, the rules, and the code are all in git,
with the same history. Nothing has to be copied from one system into another, because
there is only one.

## The common thread

None of the apps keep your data. Folder writes to your repository. Tasks reads and writes
Markdown in your repository. Bud reads your repository and makes ordinary commits and
pull requests in it. Stop using any of them tomorrow and everything they touched is still
there, in a form every other git tool understands.
