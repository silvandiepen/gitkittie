---
id: MAIL-075
title: "Mail deleted at the provider is **kept and marked**"
date: 2026-11-25
status: proposed
---

# MAIL-075: Mail deleted at the provider is **kept and marked**

**Decision.** Mail deleted at the provider is **kept and marked**: "Deleted at iCloud" (Gmail, or the account's name for other IMAP) in the list, with the time in the reader. The sync *notices* a message when it loses its last location (expunged, or its folder deleted at the provider; `sync.sqlite` schema 5, `provider_deletions`) and *confirms* it at the end of a pass over every folder, only if no folder listing brought it back and, when some folder has mail not downloaded here (history window, budget, too large, not reached yet), a `UID SEARCH HEADER Message-ID` in those folders (at most 50 per pass) did not find it; a message without a Message-ID is looked for by sender and day instead (MAIL-104). A location found again drops the mark. The mark is device state copied into the index (schema 7, `provider_deletions`; summaries carry `deletedAtProvider`), refilled after a rebuild. Per account, **"Remove mail deleted elsewhere"** (off by default; `account.json`) deletes the local copy (`.eml`, `.md`, the attachments only it used, its index row and sync state) on the sync's next pass, never for pinned mail, mail in a space, or a message with a row in the action journal (an open change, or Undo's seven days). A permanent delete made here is not a deletion "elsewhere": its copy stays for Undo (MAIL-037). UIDVALIDITY resets are not deletions

**Why.** Sil: "Give it a status deleted with some info, unless you set in the settings that you want to remove those" (GKM-011). The folder is the person's (ThreatModel §12, no automatic purge): removing files on a provider event happens only when the person turned it on, and only after the provider was checked. A move is never taken for a deletion. `ProviderDeletionTests` (store) and `MailSyncIntegrationTests.testMailDeletedElsewhereIsKeptAndMarkedAndRemovedOnlyWhenAsked` (sync against the test server). GKM-042

**Links.** MAIL-104, MAIL-037, GKM-011, GKM-042
