---
id: MAIL-044
title: "Export writes a new folder in the mail-folder layout..."
date: 2026-11-24
status: proposed
---

# MAIL-044: Export writes a new folder in the mail-folder layout...

**Decision.** Export writes a new folder in the mail-folder layout (`accounts/<id>/messages/<yyyy>/<mm>/<id>.eml` + `.md`, `blobs/`, `layout.json`, `account.json` without servers, and for a space its file). Originals are the stored bytes, checked against the recorded hash first; a changed one is reported and left out. It is staged under a hidden name and renamed when complete; nothing device-local (index, sync state, flags, folder membership, extracted text, remote-image choices, outbox) is in it

**Why.** Byte-identical originals are what any `.eml` reader, Apple Mail included, can trust; the layout keeps the Markdown's blob links working and lets the export open as a mail folder. GKM-023

**Links.** GKM-023
