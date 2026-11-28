---
id: MAIL-094
title: "**Special folders** (Sent, Drafts, Archive, Trash, Junk) are detected as before (IMAP..."
date: 2026-11-26
status: proposed
---

# MAIL-094: **Special folders** (Sent, Drafts, Archive, Trash, Junk) are detected as before (IMAP...

**Decision.** **Special folders** (Sent, Drafts, Archive, Trash, Junk) are detected as before (IMAP SPECIAL-USE, then a well-known name) and can be chosen by hand per account (`MailboxSettings.specialFolders`, role → folder). `sync.sqlite` schema 6 keeps each folder's detected role (`detected_role`) beside the role in use (`role`): every listing writes both, and a changed choice rewrites the roles in use at once (`MailStore.applyMailboxSettings`), so Archive, Move to Trash, Delete Permanently, Junk, Clean Up and the outbox's Sent copy follow the choice without waiting for a sync. A chosen folder takes the role and the detected one loses it (one folder per role); a choice for a folder that is gone, or for the inbox or the provider's All Mail and Starred, is ignored, and a folder takes only one role. Drafts are files in the mail folder, not at the provider (MAIL-025), so a Drafts choice only changes the folder's icon

**Why.** Detection gets it wrong for servers without SPECIAL-USE and folders named in other languages. A move out of Gmail's All Mail expunges for good (MAIL-036), so it is never made Archive or Trash by hand. Keeping the detected role is what lets Settings say what "Automatic" is and go back to it. `MailboxSettingsTests`, `SyncStateTests`, `MailboxSettingsIntegrationTests.testAChosenSpecialFolderIsTheRoleOnRecordAndTheDetectedOneIsKept`; `MailboxSettingsAppTests` archives into a chosen folder at the test server and no Archive folder is made. GKM-066

**Links.** MAIL-025, MAIL-036, GKM-066
