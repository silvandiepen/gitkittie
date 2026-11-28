---
id: MAIL-035
title: "Conflicts"
date: 2026-11-24
status: proposed
---

# MAIL-035: Conflicts

**Decision.** Conflicts: the provider's state wins. A flag row carries the provider's value when the person acted; it is sent only if the provider still has that value (checked at replay, and whenever the sync reads flags), otherwise it is superseded. A move or delete is sent only while the message is still in its source folder; when the sync sees it leave (moved or deleted elsewhere) the row is superseded and nothing is re-added. Only Undo of a permanent delete appends a message, from the stored original

**Why.** "Last writer by server state" (Architecture.md); never resurrect a deleted message from stale cache (ThreatModel §12). Two devices toggling the same flag can never fight: a change made elsewhere since the person looked is never overwritten. GKM-015

**Links.** GKM-015
