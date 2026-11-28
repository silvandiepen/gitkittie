---
id: MAIL-109
title: "**Blocking a sender** is a sender rule of its own kind, offered both ways as Sil chose"
date: 2026-11-26
status: proposed
---

# MAIL-109: **Blocking a sender** is a sender rule of its own kind, offered both ways as Sil chose

**Decision.** **Blocking a sender** is a sender rule of its own kind, offered both ways as Sil chose: **Always Junk** (`SenderRuleAction.alwaysJunk`) and **Always Trash** (`.alwaysTrash`). It is made, previewed (dry run, exclusions by unticking), applied and undone like every sender rule (MAIL-055), kept in `metadata/sender-rules.json`, and is one place in your rule order. It is offered in the row menu beside "See All Mail from…" on the Mac (right-click) and on iPhone and iPad (touch and hold, Block ▸), for that From address in the row's account; in the Senders view's Add Rule menu, for the sender or list; and a blocked sender's row menu offers to stop instead. Rules are listed in the Senders view, its Rule Order sheet (which can remove one) and, on iPhone and iPad, Settings ▸ Blocked Senders

**Why.** Sil, GKM-067 review (block-means: both). IMAP has no standard server-side filter, so the app does it; one rule system (MAIL-054) keeps preview, order and Undo the same for every kind. GKM-072

**Links.** MAIL-055, GKM-067, MAIL-054, GKM-072
