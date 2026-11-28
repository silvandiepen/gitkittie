---
id: TASKS-21
section: "§ 21"
title: "Review screens for actions, checks, `for` and due dates (GITKITTIE-135, GITKITTIE-136)"
date: 2026-11-28
status: accepted
---

# § 21. Review screens for actions, checks, `for` and due dates (GITKITTIE-135, GITKITTIE-136)

**Context.** The screens on top of § 20, for Tasks 1.4.0. Sil's answers stand: actions run on the
last decision with an 8-second Undo banner (⌘Z on the Mac) and Undo in the Actions history while
the card is untouched; conflicts are skipped and asked ("PETS-2 is claimed by herma — Move
anyway?"); others' requests sit behind For me / Everyone and are read-only with comments.

**Decisions made while building it:**

- **What the screens say is worked out in GitKanbanKit** (`ReviewPresentation.swift`): the "When
  decided" lines, the Actions history, the banner (`ReviewActionBanner`), due labels, the inbox
  order, the check grid and the viewport layout; `ReviewCheckSession` runs a check for both the Mac
  window and the iPhone screen. The views (`swift/TasksUI/ReviewScreenParts.swift`) only draw it,
  so both platforms say the same words and the words are unit-tested (`ReviewScreensModelTests`).
- **Checks are entries** (`ReviewEntry.check`, `hiddenIDs(for:).checks`): they wait until decided
  (however much of the checklist is answered), count in ⌘J / Next waiting, and are a page of the
  request on iPhone, between the questions and the files.
- **The banner hides itself after 8 s only when nothing waits for an answer.** With a "Move
  anyway?" pending it stays (the Undo button goes after 8 s); closing it leaves the action skipped.
  Undo on the banner takes back every card that decision moved.
- **Scaling (the spike).** Mac: the web view takes the smaller size and `pageZoom` makes up the
  difference, so the page lays out at the true width and WebKit maps clicks itself;
  `CheckWebViewTests` checks `innerWidth`/`innerHeight` at 75 % and that a synthesised click lands on
  the element drawn under it, in the page's coordinates. iPhone/iPad: the web view keeps the true
  size and is scaled with a `UIView` transform, so `device-width` is the true width; the UI test
  taps a button in the desktop preview. No fallback to real size with scrolling was needed.
- **Appearance** is forced on the web view (`NSAppearance` / `overrideUserInterfaceStyle`), which is
  what `prefers-color-scheme` reads. A check without `appearance` follows the system, not the app's
  forced dark look.
- **Native size on a device:** the size whose width is nearest the screen's (no more than 15 % wider)
  fills the screen and records the real viewport ("440x812"); the others show at their exact
  viewport, scaled down and labelled "Scaled preview", and can be answered.
- **Answers are written a second after the last one**, one write per size; a decision, a screenshot
  or closing the check writes what waits first. A note needs text; a note on a failed line keeps it
  a fail.
- **Changes on a check starts from its failed lines** ("Phone, light: … — Below the fold"),
  editable, since Changes needs a message (`ReviewCommentRequest.initialText`).
- **Inbox order:** requests that still wait and have `due` first, soonest on top, then newest first.
  "Overdue" (red) only while something waits.
- **"Which one are you?"** is an inline card at the top of the Reviews list (Mac and iPhone), per
  board, not a modal: the list stays usable before you answer. The board header (Mac, iPhone inbox)
  and the request header say "Reviewing as …".
- **Not built:** the Mac's Custom size (free resizing records `custom`) — a check without `sizes`
  already opens in a freely resizable window; opening other browsers at a size (`browser-sizing`,
  as decided). The Mac has no UI tests (they take over the screen): its views are checked offscreen
  (`ReviewScreensRenderTests`, `CheckWebViewTests`).

**Status.** Accepted.
