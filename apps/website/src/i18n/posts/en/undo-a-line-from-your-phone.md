---
title: Undoing one line of an old commit, from your phone
description: A debug line slipped into last week's commit. With GitKittie Bud on iPhone you open the commit, tap the line, and it comes back as a pull request — no clone, no git on the phone, and later edits to the same file are kept.
date: 2026-11-23
app: bud
shot: /screenshots/bud/iphone-flow-1-chosen-dark.webp
shotAlt: A commit's file in GitKittie Bud on iPhone, with one line chosen to undo
related: take-back-part-of-a-commit, split-a-commit-with-apple-intelligence, from-task-to-pull-request
---

*GitKittie Bud is not on the App Store yet. The iPhone and iPad app is real and under
test against actual repositories; this is how it works today.*

Here is a situation I am in more often than I would like. I read through a change on the
train and spot it: a `print` left in, a flag flipped for testing, a line that should never
have been committed. The fix is one line. But the commit is from last week, there are
twenty commits on top of it, and I am not at a computer.

Reverting the commit is wrong — the rest of it is fine. What I want is to take back
exactly that line, and have someone, possibly me, look at it before it lands.

## Choose the line

Open the repository, the branch, and the commit. Open the file. Every file of a commit
reads three ways on the phone — Unified, Side by Side, and the full file — with line
numbers on both sides. Turn the phone for more room in Side by Side.

Tap the line that has to go. Tap more if there are more; a bar at the bottom keeps count
of what you chose.

## Say where it goes

Then **Undo in a pull request**. You pick the branch the change goes to, keep or change the name of the
new branch it is made on, and give the pull request a title and description. Where Apple
Intelligence is available, it drafts those two from the change, on the device.

![Composing the pull request for the undone line in GitKittie Bud on iPhone](/screenshots/bud/iphone-flow-2-compose-dark.webp)

## Review it as a pull request

The change becomes an ordinary pull request — a merge request on GitLab — for you or
your team to look at. Nothing is pushed to the branch itself, and history is not rewritten.

![The pull request GitKittie Bud opened for the undone line](/screenshots/bud/iphone-flow-3-opened-dark.webp)

## What happens to everything since

The undo is worked out against the file as it is *now*, not as it was in that commit.
Each file is merged three ways: the commit, the line you took back, and today's version.
So edits made since — even on the very next line — are kept.

If the line itself changed since the commit, there is nothing sensible to undo, and Bud
makes nothing rather than guessing.

## What the phone needs

No clone and no git on the device. Bud talks to the host's API: sign in with GitHub, or
use a token for GitHub or GitLab. There is a demo repository to try the whole flow
without an account.

---

On the Mac the same idea works on your working copy instead of a pull request — that is
[taking back part of a commit without reverting it](/blog/take-back-part-of-a-commit).
