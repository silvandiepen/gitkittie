---
id: MAIL-093
title: "An account's folder choices are its own and are kept in its `account.json`..."
date: 2026-11-26
status: proposed
---

# MAIL-093: An account's folder choices are its own and are kept in its `account.json`...

**Decision.** An account's folder choices are its own and are kept in its `account.json` (`MailAccount.mailboxes`, `MailboxSettings` in MailCore), named by the provider's folder id, so every device that opens the mail folder shares them; a file without them reads as before. **Which folders sync** (`notSynced`): every folder is still listed and on record (sidebar, Settings, move targets), but one that doesn't sync is never opened: nothing new is downloaded from it, its flags are not checked, the sync never waits on it with IDLE. Mail already downloaded from it stays, with its locations. A move this device made into it settles at once (it is never listed there), and a message noticed leaving its last folder is searched for in the folders that don't sync before it is called deleted at the provider (MAIL-075), like a folder whose mail is not all here. The inbox always syncs. **Which folders show** (`hidden`) and **their order** (`order`; the rest follow in the provider's order) are the sidebar's on both platforms; Settings lists every folder. Choices are applied at once; a change to which folders sync starts the account's sync again

**Why.** Sil asked where mailboxes are configured (GKM-066). A folder is the person's at the provider, so the choice travels with the account, not the device. Keeping the folder listed while not syncing it is what keeps a moved message from being taken for a deleted one. `MailboxSettingsIntegrationTests.testAFolderThatDoesntSyncIsListedButNothingIsDownloadedFromIt` and `MailboxSettingsAppTests` against the test server. GKM-066

**Links.** MAIL-075, GKM-066
