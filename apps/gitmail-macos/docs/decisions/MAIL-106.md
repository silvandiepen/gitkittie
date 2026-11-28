---
id: MAIL-106
title: "**The Mac pauses downloading below 2 GB free** on the disk that holds the mail folder,..."
date: 2026-11-26
status: proposed
---

# MAIL-106: **The Mac pauses downloading below 2 GB free** on the disk that holds the mail folder,...

**Decision.** **The Mac pauses downloading below 2 GB free** on the disk that holds the mail folder, says so and carries on by itself when there is room; the iPhone and iPad keep their storage budget's minimum (1 GB, MAIL-051) and now share the same code and words. The pause is the shared sync's (`AccountSync.downloadPause`, `DownloadPause.swift` in MailAppModel): it looks at the free space (`volumeAvailableCapacityForImportantUsage`, purgeable space counted as free, as Finder does) when the sync starts, at most every 5 seconds while mail comes in, and once a minute; under the minimum every account's download coordinator stops, while its action replay, attachments on demand and server search stay; with room again the paused accounts start downloading with no restart. It says "Downloading paused: only 0.9 GB free on this Mac. It carries on by itself when there is room." at the foot of the Mac's sidebar with Storage Settings…, at the top of Settings ▸ Storage, and on each account ("Downloading paused · disk nearly full"); on iPhone and iPad in Mailboxes and Settings ▸ Storage as before. Freeing space in Settings looks again at once. Mail already stored is never removed to make room (MAIL-003)

**Why.** Sil: "Pause downloads below 2 GB free, say so, carry on when there's room" (GKM-067, GKM-090). His Mac fell under 1 GB and Mail stopped with nothing on screen, which read as "nothing loads". The review said the store had a 1.5 GB floor of its own; it has none (only the sync benchmark keeps a free-space limit), so this pause is the guard; GKM-091 is the floor inside the sync and plain words for other local stops. Checking as mail comes in matters on the Mac: a first sync can write gigabytes in a minute. `DownloadPauseTests` (an injected free-space value; against the test server: paused at setup, carries on by itself, pauses while running, mail that arrived meanwhile comes in after), `MobileSessionTests.testLowStorageStopsTheSyncWithAMessage`. GKM-090

**Links.** MAIL-051, MAIL-003, GKM-067, GKM-090, GKM-091
