---
id: MAIL-083
title: "Opening a server result downloads it and stores it exactly as the sync would..."
date: 2026-11-25
status: proposed
---

# MAIL-083: Opening a server result downloads it and stores it exactly as the sync would...

**Decision.** Opening a server result downloads it and stores it exactly as the sync would (`ServerSearcher.download`): under the provider location it was found at (mailbox, UIDVALIDITY, UID) through `storeSynced`, so its bytes are the provider's, a copy already stored elsewhere is matched instead of duplicated, classification and sender rules run at ingest, and the sync sees the UID as known (never downloaded twice, no longer counted as left out). A message above the on-demand threshold is stored partial, its large attachments left at the provider (`SyncCoordinator.partialCopy`, shared with the sync; MAIL-062). It then is a local result and opens in the reader; the server list drops it. A message gone from where it was found (deleted, moved, UIDVALIDITY reset) says so and asks to search again; offline says so; nothing is stored in either case

**Why.** "Fetch once, never fake" (MAIL-063): the reader only ever shows stored mail, and there is one way into the store for provider mail. Storing it under its location is what makes the sync and the next search treat it as downloaded. GKM-041

**Links.** MAIL-062, MAIL-063, GKM-041
