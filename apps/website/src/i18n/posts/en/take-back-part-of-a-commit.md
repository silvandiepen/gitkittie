---
title: Taking back part of a commit without reverting it
description: git revert is all or nothing, and cherry-pick takes the whole commit. GitKittie Bud on the Mac lets you choose lines, hunks or files of any commit and put them into your working copy or take them out — merged three ways, so newer edits stay.
date: 2026-11-23
app: bud
shot: /screenshots/bud/mac-chosen.webp
shotAlt: The commit window of GitKittie Bud on the Mac, with lines chosen in the diff
related: undo-a-line-from-your-phone, split-a-commit-with-apple-intelligence, from-task-to-pull-request
---

*GitKittie Bud is not on the App Store yet. The Mac app is under test against real
repositories; this is how it works today.*

Git has two blunt tools for "I want some of that commit". `git revert` takes the whole
commit back. `git cherry-pick` brings the whole commit over. For anything finer you are
in `git checkout -p` or a hand-made patch, deciding hunk by hunk in a terminal with no
picture of what you are doing.

Most of the time what I actually want is smaller and more specific: *these three lines of
that commit, back out please*, or *that one function from the other branch, here*.

## Open the commit

In Bud, double-click a commit in the history and it opens in a window of its own: the
whole message, every file it touched, and the diff. The diff reads three ways — Unified,
Side by Side, or the full file with the changes marked — and **Ignore Whitespace** hides
the changes that are only indentation.

![A branch history in GitKittie Bud on the Mac](/screenshots/bud/mac-history.webp)

## Choose what you mean

Click a line to choose it, and ⇧-click another to choose the range between them. Choose
a whole hunk, or a whole file. The window keeps count — "4 changed lines chosen" — so you
see the size of what you are about to do before you do it.

Then one of two things:

- **Apply to Working Copy** — the chosen changes are put into your files. This is
  cherry-picking at the scale of a line.
- **Undo in Working Copy** — the chosen changes are taken back out of your files. This
  is reverting at the scale of a line.

## Why newer edits survive

The obvious way to do this — make a patch and apply it — breaks as soon as the file
changed after the commit. Context lines no longer match and the patch is refused, or
worse, lands in the wrong place.

Bud merges each file three ways instead: the commit's version, the change you chose, and
the file as it is now. Edits made since, even on the line right next to the one you are
taking back, are kept. If a chosen line itself was changed since, Bud stops and tells you
rather than overwrite it.

## Nothing is rewritten

This is the part I like most. The result is ordinary, uncommitted changes in your
working copy. History is not touched. Look at them, run the tests, commit them with a
message that says why — or throw them away. It is the safest kind of git operation there
is, because it is not one yet.

---

The same thing on iPhone and iPad ends as a pull request instead:
[undoing one line of an old commit, from your phone](/blog/undo-a-line-from-your-phone).
And when the problem is a commit that did too much, see
[splitting a commit that did three things](/blog/split-a-commit-with-apple-intelligence).
