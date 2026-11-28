---
id: MAIL-099
title: "Several at once"
date: 2026-11-26
status: proposed
---

# MAIL-099: Several at once

**Decision.** Several at once: ⌘-click, ⇧-click and ⌘A on the Mac; Select, Select All and a bottom bar on iPhone and iPad. ⌘A / Select All reads the id of every row of the view from the index (`MailStore.threadIDs` / `messageIDs`), once: no rows are loaded for it, and mail that arrives afterwards is not part of it (as Clean Up, MAIL-060). A ⌘-click then removes one. The selection belongs to its view: another view, search or chip ends it. The reader (Mac) and the bottom bar say "312 conversations selected" and offer Archive, Move to Trash, Move To, Mark as Read or Unread, Flag and Unflag; each is one journal batch and one Undo. What leaves the view (Trash, Archive, Move) leaves the list at once, the selection ends, and the list keeps as many rows as were loaded, so it stays where it was; Undo brings them back. Move to Trash of 50 or more asks once ("Move 312 conversations to Trash?")

**Why.** GKM-071; Sil's report that deleted rows stayed selected. Ids, not rows, keep thousands cheap; reading them once keeps the action to what was seen. Trash is undoable, so one question is enough and only for many. GKM-071

**Links.** MAIL-060, GKM-071
