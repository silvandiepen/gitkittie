---
id: MAIL-073
title: "Reading choices, decided by Sil (GKM-012)"
date: 2026-11-25
status: proposed
---

# MAIL-073: Reading choices, decided by Sil (GKM-012)

**Decision.** Reading choices, decided by Sil (GKM-012): mail imported from `.eml` files arrives **unread** (File ▸ Import Messages…; it never notifies, imports are skipped by MailAttention); opening a conversation marks **every** message in it read (as built, like Gmail); a link that looks like the sender's domain is **always** warned about, in neutral words ("This looks like cloudvault.example, the sender’s domain, but it is a different one"), whether the sender is known, unknown or itself the fake

**Why.** Imported mail shows up as new until opened, which is what Sil asked for. `AppModelTests.testImportingEMLFilesAndFolders`, `AppModelTests` (whole conversation read once opened) and `ReaderContentTests.testTheLookalikeWarningIsAlwaysGivenAndWordedNeutrally` prove the three. GKM-042

**Links.** GKM-012, GKM-042
