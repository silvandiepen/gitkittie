---
id: MAIL-018
title: "A message exists when its `.eml` exists"
date: 2026-11-24
status: proposed
---

# MAIL-018: A message exists when its `.eml` exists

**Decision.** A message exists when its `.eml` exists. Writes go journal → blobs → `.md` → `.eml` → index → mapping, each file staged, fsynced and renamed; the next open finishes or undoes an interrupted write from the journal (`<Application Support>/Mail/state/journal/`)

**Why.** One recovery path for crashes and errors; the original is the commit point, everything else is derived. GKM-005

**Links.** GKM-005
