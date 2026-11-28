---
id: MAIL-111
title: "**Removing (or turning off) a blocking rule moves nothing back**"
date: 2026-11-26
status: proposed
---

# MAIL-111: **Removing (or turning off) a blocking rule moves nothing back**

**Decision.** **Removing (or turning off) a blocking rule moves nothing back**: what it moved stays in Junk or Trash, and new mail is no longer moved. Its preview says so ("…stays there: removing the rule doesn't move it back"), on the Mac and on iPhone and iPad; Undo right after applying is the way to take the moves back

**Why.** Moving mail back would need to know which mail you left in Junk on purpose since; the provider's folders are yours. Proven against GreenMail: deals reach Junk and promos Trash at the provider, flagged mail stays in the inbox, a new deal reaches Junk after the sync, Undo brings the promos back (`BlockSenderAppTests`). Not yet run against Gmail or iCloud (GKM-004). GKM-072

**Links.** GKM-004, GKM-072
