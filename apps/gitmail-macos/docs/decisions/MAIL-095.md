---
id: MAIL-095
title: "Folders are **created, renamed and deleted at the provider** from Settings..."
date: 2026-11-26
status: proposed
---

# MAIL-095: Folders are **created, renamed and deleted at the provider** from Settings...

**Decision.** Folders are **created, renamed and deleted at the provider** from Settings (`FolderEditor` in MailSync), each over a connection of its own while the account's sync is stopped (a pass that listed before the change would record the old list after it), then the folders are listed again and recorded at once. A new name is turned into the provider's id by the adapter (`MailboxSession.folderID(for:)`: the server's hierarchy delimiter, modified UTF-7); an empty name, one that holds the delimiter, or one already taken (any case) is refused. The inbox and the provider's All Mail and Starred are never renamed or deleted. A rename (IMAP RENAME, with the folders inside it) moves the folder's sync state, cursor, locations, open journal rows and index memberships to the new name (`MailStore.renameSyncedFolder`), so its mail is not downloaded again, and the account's choices follow it; a changed UIDVALIDITY is still handled as a reset. Deleting asks first, names the provider and how many messages downloaded here are in it, and says it can't be undone; the copies stay, marked deleted at the provider, unless "Remove mail deleted elsewhere" is on (MAIL-075), and the choices for it go

**Why.** A folder is shared with every other app and device, so editing it is a provider operation, not a local label. Re-downloading a renamed folder would cost a whole folder of bandwidth for a name change. GreenMail 2.1.3 drops a connection that deletes a folder an earlier session left selected (README), so the tests end each sync on another folder. `MailboxSettingsIntegrationTests.testFoldersAreCreatedRenamedAndDeletedAtTheProvider`, `MailboxSettingsAppTests`. GKM-066

**Links.** MAIL-075, GKM-066
