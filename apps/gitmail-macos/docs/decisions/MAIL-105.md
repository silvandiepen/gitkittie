---
id: MAIL-105
title: "A noticed deletion whose check could not tell (MAIL-104"
date: 2026-11-26
status: proposed
---

# MAIL-105: A noticed deletion whose check could not tell (MAIL-104

**Decision.** A noticed deletion whose check could not tell (MAIL-104: too many hits to compare by header, a hit gone between search and fetch, a folder gone or reset under the search, or a stored copy that can't be read) goes behind the others and waits before it is checked again. `sync.sqlite` schema 7 records per notice when a check last could not tell (`checked_at`) and how many times in a row (`undecided_checks`); `deletionCandidates` gives the notices no check has failed to decide first, oldest first, then the least recently checked. A pass still checks at most `deletionChecksPerPass` (50); a notice waits out its back-off without a search (`SyncOptions.undecidedDeletionBackoff`: 15 minutes after the first undecided check, doubling with each one after, at most a day), so every notice is checked again within a day and a newer one is never held up. Failing to decide never confirms a deletion, however often it happens: a move is never taken for a deletion (MAIL-075). When no folder has mail left at the provider, no search is needed and every notice is confirmed as before.

**Why.** Without it, more than 50 notices that can never be decided spent every pass's checks, oldest first, and a newer deletion queued behind them was never marked; they also cost a search per folder on every pass, forever. Least recently checked first bounds the wait of every notice by the number of notices, and the back-off bounds what an undecidable one costs. The record is device state beside the notice, so it survives a restart. `MailSyncIntegrationTests.testCandidatesThatCannotBeDecidedDoNotHoldUpANewerOne` against the test server (55 undecidable, then a newer one deleted elsewhere: marked on the next pass, and each undecidable one checked again within two passes without the back-off, none marked); `ProviderDeletionTests` (order, migration from schema 6); `DeletionProbeTests` (the back-off). GKM-076

**Links.** MAIL-104, MAIL-075, GKM-076
