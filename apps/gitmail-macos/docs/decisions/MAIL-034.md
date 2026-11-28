---
id: MAIL-034
title: "Everyday actions (read, flag, move, archive, trash, delete from Trash) are rows in an..."
date: 2026-11-24
status: proposed
---

# MAIL-034: Everyday actions (read, flag, move, archive, trash, delete from Trash) are rows in an...

**Decision.** Everyday actions (read, flag, move, archive, trash, delete from Trash) are rows in an action journal in `state/<account-id>/sync.sqlite` (schema 4), written in the same transaction as their local effect. The window shows the provider's last-synced state with open rows laid over it, everywhere the index is written (sync, rebuild, UIDVALIDITY reset). Each account's `ActionReplayer` (MailSync) sends them on its own connection, once: a row is marked only after the provider confirmed it, and every operation is safe to repeat (`+FLAGS`/`-FLAGS`; a move or expunge of a UID that is gone does nothing; a restore searches for the exact bytes before appending). Rows the provider refuses five times are shown as failed, with Try Again and Discard

**Why.** An action is one device's intent, like a send (MAIL-022); local first keeps the app instant and offline-capable; one journal beside the mapping makes the overlay and the replay consistent after a crash. GKM-015

**Links.** MAIL-022, GKM-015
