---
id: TASKS-13
section: "§ 13"
title: "Refused writes show under every screen, with what can be done"
date: 2026-11-25
status: accepted
---

# § 13. Refused writes show under every screen, with what can be done

**Decision.** The Mac has no activity list, so a write the provider refused shows in a banner
under the detail pane (`SyncFailuresBanner`, `swift/TasksUI/SyncFailures.swift`) with Retry,
Discard and Show What It Was, instead of as a red "Not sent: …" line in `errorMessage`. How the
outbox keeps and merges writes is the iOS app's Decision 8; the code is shared.

**Status.** Accepted.
