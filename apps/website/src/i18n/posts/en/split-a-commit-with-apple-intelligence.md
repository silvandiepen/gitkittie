---
title: Splitting a commit that did three things
description: A commit that fixes a bug, renames a file and tweaks a style is three commits pretending to be one. GitKittie Bud suggests the split on your Mac with Apple Intelligence, you review it, and a safety branch means you can always go back.
date: 2026-11-23
app: bud
shot: /screenshots/bud/mac-suggest.webp
shotAlt: GitKittie Bud on the Mac suggesting how to split a commit into separate commits
related: take-back-part-of-a-commit, undo-a-line-from-your-phone, agents-work-the-board
---

*GitKittie Bud is not on the App Store yet. The Mac app is under test against real
repositories; this is how it works today.*

Small commits are easy to review, easy to revert and easy to understand a year later.
Everyone agrees, and then everyone — me included, and every coding agent I have worked
with — makes a commit called "Fix login and clean up" that touches eleven files for
three unrelated reasons.

In plain git, splitting it means an interactive rebase, stopping at the commit, resetting
it, and staging the pieces back one by one with `git add -p`. It works. It is also the
kind of thing you do once, get wrong, and never try again.

## Ask for a split

Open the commit in Bud and choose **Suggest a Split**. Bud reads the commit's changes and
proposes separate commits, each with a message of its own: *Fix the session check on
login*, *Rename AuthView to SignInView*, *Tighten the button spacing*.

The suggestion is made by Apple's on-device model, on your Mac. There is no key to set
and nothing is sent anywhere. The same commit gets the same suggestion every time, so
asking twice does not give you a different answer to pick from.

## Use it, or make your own

Choose a suggested commit and its changes are ticked in the diff and its message filled
in. Adjust the ticks if the model put a hunk in the wrong place, edit the message, and
confirm. That part is split off into a new commit; repeat for the next one.

You can also skip the suggestion entirely: tick the files or hunks that belong together,
write the message yourself, and split. The model is a head start, not the decision.

## The way back

Splitting rewrites history, so Bud is careful about it:

- It needs a clean working tree first, so nothing of yours gets mixed in.
- It saves a safety branch before it changes anything.
- Right after, there is a one-click **Undo** that puts everything back.
- Pushing the rewritten branch is a separate step, done with a lease, so it never
  overwrites work someone else pushed in the meantime.

That last one matters more than it sounds. The scary part of rewriting history is
not the rewrite. It is the force-push.

## Where this is going

Splitting is the first of a set: combining commits, reordering them by dragging, and
rewording an old message are being rebuilt on the same rewrite engine before they ship,
so every one of them gets the same safety branch and the same Undo.

---

When you only want to take part of a commit back rather than split it, see
[taking back part of a commit without reverting it](/blog/take-back-part-of-a-commit).
