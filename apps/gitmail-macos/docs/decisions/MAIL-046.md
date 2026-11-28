---
id: MAIL-046
title: "The sync stores each fetched batch as one write"
date: 2026-11-24
status: proposed
---

# MAIL-046: The sync stores each fetched batch as one write

**Decision.** The sync stores each fetched batch as one write: one journal file lists its messages, every file is still flushed before its rename, each directory is flushed once, and the index and the sync state take the batch in one transaction each. A message is still wholly there or wholly absent after a crash; the cursor is checkpointed only after the batch returns. `ingest` is the same path for one message. Classification (MAIL-038) runs on every message the batch wrote, after it is durable, in one index transaction

**Why.** About 12 flushes and commits per message made disk the cost of a first sync; the guarantee is per message, the flushes need not be. Performance.md. GKM-035

**Links.** MAIL-038, GKM-035
