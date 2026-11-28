---
id: MAIL-064
title: "Pins are on a message, a conversation (by thread id"
date: 2026-11-25
status: proposed
---

# MAIL-064: Pins are on a message, a conversation (by thread id

**Decision.** Pins are on a message, a conversation (by thread id; a pin follows the conversation when an older message joins) or a space, kept in `metadata/pins.json` (device; CloudKit with GKM-026). A pin means "all of it here": the partial messages it covers are completed, now when online and by each sync pass otherwise (`pinnedPerPass`). Completing is one way: originals in the mail folder are never evicted, pinned or not. Eviction (`evictCache(toFit:)`, automatic above `offlineCacheBudgetBytes`, default 2 GB, and "Free Up Space") only removes cached parts of partial messages that were fetched on demand, are not pinned and can be fetched again (the message still has a provider location), least recently used first; parts that came with the text stay, and unreferenced cache files go first

**Why.** The mail folder is the user's archive and must not shrink behind their back; the cache is the only re-fetchable thing. A pinned space is all present offline by construction. GKM-036

**Links.** GKM-026, GKM-036
