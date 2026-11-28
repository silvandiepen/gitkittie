---
id: MAIL-029
title: "A message that leaves every folder at the provider (expunged, Trash emptied) loses its..."
date: 2026-11-24
status: proposed
---

# MAIL-029: A message that leaves every folder at the provider (expunged, Trash emptied) loses its...

**Decision.** A message that leaves every folder at the provider (expunged, Trash emptied) loses its locations, drops out of folder views and stays in the mail folder and All Mail. Nothing local is deleted automatically. Answered by Sil (GKM-011): kept and marked as deleted at the provider, removed only by a setting; see MAIL-075

**Why.** No automatic purge in the MVP (ThreatModel.md §12); deleting the user's files on a provider event is the riskier default. GKM-011

**Links.** GKM-011, MAIL-075
