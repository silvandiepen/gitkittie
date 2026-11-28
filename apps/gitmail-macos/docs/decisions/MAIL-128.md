---
id: MAIL-128
title: "**The encrypted archive is one file of everything the person owns**, `<name>.gkmarchive`"
date: 2026-11-27
status: proposed
---

# MAIL-128: **The encrypted archive is one file of everything the person owns**, `<name>.gkmarchive`

**Decision.** **The encrypted archive is one file of everything the person owns**, `<name>.gkmarchive`: the whole mail folder (originals byte for byte, Markdown, blobs, `account.json` with servers and without passwords, spaces with their rules, drafts, `layout.json`) and the device folder's own metadata (`classification.json`, `sender-rules.json`, `unsubscribes.json`); never device state (index, sync state, journal, outbox, caches, partial messages, pins, preferences). Changed originals are left out and reported, partial messages completed first or left out, as export does (MAIL-044). Format 1: plaintext authenticated header, then AES-256-GCM records of at most 1 MiB, each binding the header's SHA-256, its index and a final flag; inside, a stream of files with their SHA-256. Restore goes into a new, empty folder, all or nothing, and the store rebuilds the index on open (Architecture.md, "Encrypted archive")

**Why.** A backup has to restore spaces, rules and corrections, not only messages, and must never carry another device's sync position (MAIL-013) or a password. Streaming records keep memory flat for a 10 GB mailbox (Sil's projected size, GKM-026 design). Binding index and final flag makes reordering, dropping and cutting detectable without a trailing MAC over the whole file. CryptoKit only, no primitives of our own. Servers stay in `account.json` (unlike export) because this is a backup to restore, and a restored account then only needs its password. `EncryptedArchiveTests`. GKM-032

**Links.** MAIL-044, MAIL-013, GKM-026, GKM-032
