---
id: MAIL-066
title: "Fetching and storing overlap"
date: 2026-11-25
status: proposed
---

# MAIL-066: Fetching and storing overlap

**Decision.** Fetching and storing overlap: while the store (its own actor) writes one fetched batch, the next is downloading. At most one batch is in the store, batches are stored in order, and an import that stops (error, cancel, budget, slice end) waits for the batch being stored before it returns, so cursors still cover only durable writes (MAIL-046). While a history budget applies, there is no overlap: each batch is weighed against what is actually stored (a server's RFC822.SIZE is only an estimate), and a partial message by its skeleton, the bytes it adds

**Why.** About half of a first sync on a 50 ms link was waiting for the next fetch while storing, and the other way round. Performance.md. GKM-038

**Links.** MAIL-046, GKM-038
