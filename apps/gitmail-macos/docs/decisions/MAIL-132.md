---
id: MAIL-132
title: "**Make Task** (Message menu, the row menus, the reader's More menu on iOS) opens..."
date: 2026-11-27
status: proposed
---

# MAIL-132: **Make Task** (Message menu, the row menus, the reader's More menu on iOS) opens...

**Decision.** **Make Task** (Message menu, the row menus, the reader's More menu on iOS) opens GitKittie Tasks with `gitkittie-tasks://new?title=…&body=…` (`TaskHandoff`): the subject as the title (else "Message from <sender>"), and as the description who it is from (their name, else the address), the day, and `[Open in Mail](<MAIL-131 link>)`. **Never the message's text or attachments.** Tasks only fills in its new-task sheet; the person picks the board and lane, can edit everything, and presses Create. Without Tasks installed, Mail says so

**Why.** A card is committed to a Git repository that may be shared or public (ThreatModel §7): the least that makes the task useful goes in, and the person sees all of it before it is saved. Tasks' existing ways in (images dropped on the Dock icon, the iPhone share extension for screenshots, agent access over MCP) carry images or need a token; a URL that only fills in a sheet is the smallest new way in and needs no shared container between two products. Mail does not import Tasks' code (apps never import each other): both build or read the same documented URL. GKM-033

**Links.** MAIL-131, GKM-033
