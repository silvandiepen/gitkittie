---
id: MAIL-026
title: "What is stored is decided by the remote mapping, never by a cursor"
date: 2026-11-24
status: proposed
---

# MAIL-026: What is stored is decided by the remote mapping, never by a cursor

**Decision.** What is stored is decided by the remote mapping, never by a cursor. Each folder's cursor (highest UID) is checkpointed only after the messages it covers are written, and only separates new mail from history. A message seen again (UIDVALIDITY reset, a move, a copy in a second folder) is attached to the stored message only when its bytes are identical; a matching Message-ID or fingerprint alone never merges

**Why.** A lagging cursor costs a re-check, never a lost message; a wrong merge would silently hide a message, a duplicate is visible and harmless. GKM-011

**Links.** GKM-011
