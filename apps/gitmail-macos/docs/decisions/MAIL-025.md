---
id: MAIL-025
title: "Drafts are files in `Mail/drafts/<id>/` with revisions"
date: 2026-11-24
status: proposed
---

# MAIL-025: Drafts are files in `Mail/drafts/<id>/` with revisions

**Decision.** Drafts are files in `Mail/drafts/<id>/` with revisions; a save from a stale revision, or a sync tool's conflict file, becomes a separate draft marked as a conflict copy

**Why.** The mail folder may be synced by iCloud Drive or GitKittie Folder; preserving both edits is the rule for drafts (Architecture.md, Multi-device sync). GKM-013

**Links.** GKM-013
