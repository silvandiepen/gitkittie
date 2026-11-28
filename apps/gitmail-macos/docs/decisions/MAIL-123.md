---
id: MAIL-123
title: "**The sync has a free-space floor of its own**, under the app's pause (MAIL-106)"
date: 2026-11-27
status: proposed
---

# MAIL-123: **The sync has a free-space floor of its own**, under the app's pause (MAIL-106)

**Decision.** **The sync has a free-space floor of its own**, under the app's pause (MAIL-106): `SyncOptions.freeSpaceFloor` (`FreeSpaceFloor` in MailStore: a minimum and a free-space reader) is checked by `SyncCoordinator` before each batch it downloads (whole, part by part, and pinned mail), and again by the store before it writes a synced batch (`storeSynced` / `storeSyncedPartials` with `floor:`), counting the batch's bytes. Under it nothing of the batch is fetched or written; the store throws `MailStoreError.diskNearlyFull`, the pass stops with the activity `.pausedForSpace(freeBytes:minimumFreeBytes:)`, looks again every `SyncOptions.localStopRecheck` and carries on by itself when there is room. A write that fails for space anyway (`ENOSPC`, `SQLITE_FULL`) is the same pause. The app passes its own minimum and reader (`AccountServices.freeSpaceFloor`: `minimumFreeBytes` and `freeSpace`, 2 GB on the Mac, the budget's minimum on iPhone and iPad), so there is one number; `AccountSync` shows a floor's pause as the MAIL-106 pause (`downloadPause`, "Downloading paused · disk nearly full"), never as offline. What the person asks for (an attachment opened, a message found on the server, an import) is not held to the floor, as MAIL-106 decided

**Why.** GKM-091: the review said the store had a 1.5 GB floor; it had none, and the app's checks (at start, every 5 s as mail comes in, once a minute) leave room for a fast first sync, or a sync started some other way, to fill the disk, which on Sil's Mac ended in ENOSPC and "Offline · trying again". Checking before the download as well as before the write means a batch that can't be stored isn't downloaded. No separate, lower number: a second threshold would be a second thing to keep right. `LocalStopIntegrationTests` against the test server (free space drops mid-pass: stopped before the third batch, nothing half written, carries on to all 20 with none twice; the store refuses a batch one byte short and writes nothing), `DownloadPauseTests.testTheSyncsOwnFloorStopsABatchAndShowsAsThePause`. GKM-091

**Links.** MAIL-106, GKM-091
