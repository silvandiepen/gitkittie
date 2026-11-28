---
id: MAIL-069
title: "iOS lifecycle (MAIL-053 as built)"
date: 2026-11-25
status: proposed
---

# MAIL-069: iOS lifecycle (MAIL-053 as built)

**Decision.** iOS lifecycle (MAIL-053 as built): `MobileSession` stops every account's sync and IDLE and pauses attachment text when the scene goes to the background, holding a `beginBackgroundTask` for up to 25 s while the outbox has a message in `sending`; becoming active first checks the mail folder against the index (Files may have added or removed `.eml` files; a different count rebuilds the index), then starts the sync. `BGAppRefreshTask` (`app.hakobs.gitmail.refresh`, earliest 15 min) runs one sync pass per account and posts notifications for what arrived; `BGProcessingTask` (`app.hakobs.gitmail.processing`, on power and network) also checks the folder and extracts attachment text. Background runs rely on the default file protection class (MAIL-068): a task that starts before the first unlock after a restart finds the store unreadable and does nothing. Neither runs over the open app; when iOS cancels one, the sync stops and the task reports it cut short

**Why.** One owner for the lifecycle, testable without UIKit; nothing promises instant notifications (Settings says so). GKM-027

**Links.** MAIL-053, MAIL-068, GKM-027
