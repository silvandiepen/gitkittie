---
id: MAIL-065
title: "A history slice ends after `historySlice` (20 s) or `historyPerPass` (10,000)..."
date: 2026-11-25
status: proposed
---

# MAIL-065: A history slice ends after `historySlice` (20 s) or `historyPerPass` (10,000)...

**Decision.** A history slice ends after `historySlice` (20 s) or `historyPerPass` (10,000) messages, whichever comes first; then the next pass lists every folder again, imports new mail, and continues

**Why.** Slices of 500 made a 50,000-message first sync about 100 passes, each listing every folder (SELECT + UID SEARCH ALL); new mail still waits at most a slice plus a listing. Performance.md. GKM-038

**Links.** GKM-038
