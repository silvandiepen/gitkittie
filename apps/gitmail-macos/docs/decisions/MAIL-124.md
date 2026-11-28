---
id: MAIL-124
title: "**A sync that stops because of this device says so in plain words** and is never shown..."
date: 2026-11-27
status: proposed
---

# MAIL-124: **A sync that stops because of this device says so in plain words** and is never shown...

**Decision.** **A sync that stops because of this device says so in plain words** and is never shown as a network problem: a store error is read as a `LocalStoreProblem` (out of space without a floor, the mail folder or Mail's records not writable, the folder or its disk gone, records damaged; from the POSIX, SQLite and Cocoa codes), the pass stops with `.cannotStore(problem, reason:)`, and the account's status reads "Can’t save mail · the mail folder is read-only" with what to do on the next line ("Give yourself permission to write to it again and it carries on by itself."). It tries again every `localStopRecheck` (the app's free-space interval, a minute), not on the reconnect backoff, and carries on by itself when the cause is gone. A failed write leaves what a crash would: no file in the mail folder, and its journal entry, which the store's one recovery path clears on the next open (AtomicWriter.swift), so nothing is stored twice

**Why.** GKM-090's outcome: every local reason a sync stops gets words as plain as the space pause. The technical reason stays in the log, not in the sidebar. `LocalStopIntegrationTests.testAReadOnlyMailFolderStopsTheSyncWithPlainWordsAndItCarriesOnWhenWritable`, `DownloadPauseTests.testAReadOnlyMailFolderIsSaidInWordsAndTheSyncCarriesOnWhenItIsWritable`, `LocalStopTests` (the mapping), `DownloadPauseTests.testEveryStopOnThisMacSaysWhatHappenedAndWhatToDo`. GKM-091

**Links.** GKM-090, GKM-091
