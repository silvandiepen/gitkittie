---
id: MAIL-101
title: "Hundreds of actions go to the provider in batches"
date: 2026-11-26
status: proposed
---

# MAIL-101: Hundreds of actions go to the provider in batches

**Decision.** Hundreds of actions go to the provider in batches: the replay groups a journal's rows per folder and target and sends at most `ActionReplayer.batchSize` (500) UIDs per STORE, MOVE or COPY, written as UID ranges (`1:300`) by the IMAP layer, so a command stays short. `ReplayReport.commands` counts the commands that changed something. Proven against GreenMail: 620 messages marked read in 2 STOREs, moved to Trash in 2 MOVEs, and their Undo in 2 MOVEs (`MailActionsIntegrationTests`); 320 from one sender through the app, Select All, Trash and Undo (`SelectionAppTests`). A row whose move the provider confirmed (it reported the new UID) is done even when a sync saw the message leave its folder before the replay recorded it and superseded the row: that sync was seeing this move, and Undo must cover it

**Why.** Providers limit command length and rate (Gmail, iCloud); one command per message would be hundreds of round trips. Not yet run against Gmail or iCloud (GKM-004). GKM-071

**Links.** GKM-004, GKM-071
