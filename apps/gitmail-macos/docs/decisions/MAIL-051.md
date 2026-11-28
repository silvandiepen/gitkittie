---
id: MAIL-051
title: "On iOS the mail folder is `<container>/Documents/Mail`, visible in Files under On My..."
date: 2026-11-24
status: proposed
---

# MAIL-051: On iOS the mail folder is `<container>/Documents/Mail`, visible in Files under On My...

**Decision.** On iOS the mail folder is `<container>/Documents/Mail`, visible in Files under On My iPhone (the app sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`); device state stays in `Application Support/Mail`. No iCloud Drive or picked external folder for the mail folder in the first iOS release. Files use `NSFileProtectionCompleteUntilFirstUserAuthentication`, the iOS app marks the device folder's `cache/` excluded from backup, and storage has budgets (Architecture.md, iOS; both set up by GKM-027)

**Why.** The person can see and copy their `.eml` files, as on the Mac. iCloud Drive evicts files to placeholders and syncs conflicting copies, which the store's atomic writes and hashes would see as corruption; devices share mail through the providers (MAIL-001). Background sync writes while the phone is locked, so `Complete` protection would fail it. A rebuildable cache in a backup only costs the person's iCloud space. GKM-025

**Links.** GKM-027, MAIL-001, GKM-025
