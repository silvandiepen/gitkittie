---
id: MAIL-042
title: "A space is one file, `Mail/spaces/<space-id>.json` (format 1)"
date: 2026-11-24
status: proposed
---

# MAIL-042: A space is one file, `Mail/spaces/<space-id>.json` (format 1)

**Decision.** A space is one file, `Mail/spaces/<space-id>.json` (format 1): name, icon, colour, order, rules, `members` and `excluded`. Members are named by local message id, with account, Message-ID and original SHA-256 beside it; the index keeps a rebuildable copy (`space_members`)

**Why.** Mail is never copied: a message in several spaces is one `.eml`. One file per space keeps a synced folder's conflicts to one space. The extra keys let GKM-026 match the same message on a device whose local ids differ. GKM-022

**Links.** GKM-026, GKM-022
