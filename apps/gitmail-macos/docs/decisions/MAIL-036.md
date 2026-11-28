---
id: MAIL-036
title: "Archive goes to the account's SPECIAL-USE `\\Archive` folder, else its `\\All` folder..."
date: 2026-11-24
status: proposed
---

# MAIL-036: Archive goes to the account's SPECIAL-USE `\Archive` folder, else its `\All` folder...

**Decision.** Archive goes to the account's SPECIAL-USE `\Archive` folder, else its `\All` folder (Gmail's All Mail: a move out of the inbox removes the Inbox label), else an `Archive` folder created on first use. Trash goes to `\Trash`, else a `Trash` folder created on first use. Moves use UID MOVE, else UID COPY + `\Deleted` + UID EXPUNGE of exactly those UIDs (never a plain EXPUNGE). Nothing is ever expunged from a `\All` folder: a move out of All Mail is a COPY (Gmail adds the label), and delete-permanently from All Mail is refused. The Archive folder is created silently: decided by Sil, MAIL-077

**Why.** Gmail's expunge behaviour depends on an account setting (Auto-Expunge, "when a message is expunged from the last visible folder"), so a label-folder move into All Mail is safe and an expunge from All Mail is not. Not yet run against Gmail or iCloud (GKM-004). GKM-015

**Links.** MAIL-077, GKM-004, GKM-015
