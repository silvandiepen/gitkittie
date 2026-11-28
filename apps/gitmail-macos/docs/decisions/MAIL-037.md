---
id: MAIL-037
title: "Every action can be undone (⌘Z, with Redo)"
date: 2026-11-24
status: proposed
---

# MAIL-037: Every action can be undone (⌘Z, with Redo)

**Decision.** Every action can be undone (⌘Z, with Redo): Undo adds the inverse rows; rows not sent yet cancel out and send nothing; a move the provider has goes back; a permanent delete — offered only in Trash, after a confirmation — is undone by appending the stored original (MAIL-029 keeps it). Settled rows stay seven days for this. With CONDSTORE (RFC 7162) the sync reads only flags changed since the folder's checkpointed HIGHESTMODSEQ, reset with UIDVALIDITY; without it, it reads every flag as before

**Why.** ThreatModel §12, ordinary trash and move mistakes. The CONDSTORE path is not exercised by the GreenMail test server (no CONDSTORE); the fallback is. GKM-015

**Links.** MAIL-029, GKM-015
