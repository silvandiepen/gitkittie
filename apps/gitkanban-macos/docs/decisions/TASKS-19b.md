---
id: TASKS-19b
section: "§ 19"
title: "Changes needs a message; earlier comments are offered; a full-screen pager on iPhone and iPad (GITKITTIE-126/127/095)"
date: 2026-11-28
status: accepted
---

# § 19. Changes needs a message; earlier comments are offered; a full-screen pager on iPhone and iPad (GITKITTIE-126/127/095)

**Decision.**

- **Changes is never sent without a comment.** `ReviewStatus.needsComment` / `ReviewDecisionRule`
  (`swift/GitKanbanKit/Sources/GitKanbanKit/ReviewDecisions.swift`); `AppModel.decide` (one file,
  a selection) and `decideAll` refuse `changes-requested` without a non-empty comment, set
  `errorMessage`, and write nothing. With one, the decision and the comment go in **one write**
  with the same time. Every screen asks first: the comment sheet (`swift/TasksUI/ReviewCommentSheet.swift`)
  opens with the field focused, and its send button waits for text. Bulk Changes (a selection,
  or every waiting file of a request) asks for one message, which every chosen file gets, also a
  file that already asked for changes. Approve and Reject need no comment.
- **Why this fits the contract.** The board's review workflow (`Agents/review-workflow.md`) has
  the agent act on `changes-requested` by making a redo "carrying out the comments": a decision
  without one leaves it guessing. `comments` is shared and append-only, so writing one with the
  decision is within the reviewer's fields; nothing in the file format changes. The rule is the
  app's; an agent never decides, so the agent tools are untouched.
- **Undo.** After a decision the full-screen viewer offers Undo for five seconds (`ReviewUndo`,
  `AppModel.undo`): each file the action changed gets its previous decision in one write. Undo is
  not held to the comment rule (a file going back to Changes still has the comment it was asked
  with), and it does **not** remove a comment written with the decision: comments are never taken
  out of a request.
- **Earlier comments.** `ReviewRequest.commentSuggestions(excluding:)`: the request's comments,
  newest first by `at` (file order when a time cannot be read), each text once ignoring case and
  surrounding space, without the agent's own (`requested_by`), without comments that point at a
  marked-up image, and without what the file already has. Shown as chips in the comment sheet and
  as a menu beside the inline comment fields (Mac and iOS); a tap fills the field, it does not send.
- **Full-screen viewer (iPhone and iPad).** Tapping a file's picture opens `ReviewFullScreenView`
  over black, status bar hidden. Its pages are the files the request screen shows (its filter),
  fixed when it opens (`ReviewPager`), starting at the tapped one; questions stay on the request
  screen. Pictures zoom in a UIKit scroll view (pinch, double tap, pan when zoomed; the pager takes
  a swipe at the picture's edge) and a downward pull closes when not zoomed. Approve / Changes /
  Reject sit at the bottom; after a decision it goes to the next waiting page (wrapping), with a
  confirmation and Undo. Text and Markdown files show as text; other kinds as on the request
  screen. Picking an option of a pick-one group is one write now (`AppModel.pick`), also on the
  iPhone request screen.
- **Finding what waits.** Waiting is a filled tag in the accent everywhere (request header, select
  grid, Mac cards, the viewer); answered files are dimmed in the select grid and on the Mac. Group
  headers show "N waiting of M" (iOS select grid, Mac), and on the Mac a group's answered files
  can be folded away. Next Waiting is a labelled button with the count (iPhone header, Mac
  toolbar). The progress strip (`ReviewProgressStrip`) draws every page as a tick in one canvas,
  waiting ones bright, so it works for a request of any length; tap or drag along it to go there.
- **Colours (GITKITTIE-095).** Rows, bars and floating controls used the system's greys
  (`secondarySystemGroupedBackground`, `.regularMaterial`, `.bar`). The theme gains `Theme.bar`
  (dark `#131C2C`, between panel and card; high contrast `#141D2E`) and `themedRows()` /
  `themedBar(in:)`, used in place of those. `ThemeTests` check text at AA on every dark surface and
  now run in the Tasks iOS unit tests too. The share extension keeps the system colours: it does
  not compile the theme.

**Status.** Accepted.
