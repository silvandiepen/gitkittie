---
id: MAIL-068
title: "iOS storage budget defaults, until Sil confirms them (he chose the smaller set"
date: 2026-11-25
status: proposed
---

# MAIL-068: iOS storage budget defaults, until Sil confirms them (he chose the smaller set

**Decision.** iOS storage budget defaults, until Sil confirms them (he chose the smaller set: MAIL-079): a folder's newest 200 messages first, then older mail up to 500 MB per account (the sync's existing byte budget; "older mail paused at the storage limit" when reached), a 500 MB device cache trimmed least recently used and excluded from backup (crash records of attachment text are never evicted), and the sync stops with a message under 1 GB free. Mail already stored is never deleted to make room. File protection is iOS's default class for app files, `CompleteUntilFirstUserAuthentication` (readable by background sync once the phone has been unlocked after a restart); the app sets no Data Protection entitlement, so no capability change on the App ID, and files that must be stricter (Quick Look copies) are written with `.completeFileProtection` per file. The 30-day first-sync window in Architecture.md needs a date-based history option in MailSync and follows after GKM-038 (done: MAIL-072, GKM-039)

**Why.** The sync only limits history by count and bytes today; the parallel sync work (GKM-036/038) owns MailSync. A byte budget bounds what a phone holds just as well, and is shown honestly. GKM-027

**Links.** MAIL-079, GKM-038, MAIL-072, GKM-039, GKM-036, GKM-027
