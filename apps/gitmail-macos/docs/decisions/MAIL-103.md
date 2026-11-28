---
id: MAIL-103
title: "An action takes its mail out of the list it was made from at once, whatever that list..."
date: 2026-11-26
status: proposed
---

# MAIL-103: An action takes its mail out of the list it was made from at once, whatever that list...

**Decision.** An action takes its mail out of the list it was made from at once, whatever that list is (a category, a search with filters, a sender, a space, a folder): the list reloads from the index, the marks lose rows no longer shown, and the category counts, the badge, the space counts and the Senders numbers are read again in the same step (`MailActions.onMailChanged`, `AppModel.refreshAfterMailChange`). Undo and Redo do the same. Nothing waits for the sync

**Why.** Sil: "I selected multiple and then did delete, then they should disappear, maybe show in the trash then, but not in my selections" (GKM-075). Counts that lag the list until the next sync read as the delete not having worked. GKM-075

**Links.** GKM-075
