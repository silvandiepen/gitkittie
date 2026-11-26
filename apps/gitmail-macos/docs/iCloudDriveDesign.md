# One shared iCloud Drive mail folder (GKM-026 design)

**Status: proposed, waiting for Sil's OK.** Nothing here is built. Decisions MAIL-120..122 record it
as proposed; review `GitKittie/review/GKM-026-icloud-drive-design` asks the open questions.

Sil decided on 2026-11-26 (review GKM-042-followups, `icloud-drive-mac`): **one shared iCloud Drive
folder for Mac and iPhone**, instead of a folder per device with only metadata in CloudKit. The mail
folder, its `account.json`, spaces, rules and corrections live in iCloud Drive and every device works
from it. This page works out how, against the code as it is on `main` (2026-11-26).

## Summary of the recommendation

1. **One iCloud container, `iCloud.app.hakobs.gitmail`**, with the mail folder at `Documents/Mail`.
   Only what the person owns goes there: originals, derived Markdown, accounts, spaces, drafts and the
   shared metadata. Index, sync state, the outbox, caches and partial messages stay on each device,
   as they do now (MAIL-013). Passwords stay in each device's Keychain.
2. **One writer per account.** One device (by default the Mac that already has the mail) writes an
   account's messages into the folder. It holds a lease in `accounts/<id>/writer.json` that it renews
   while it syncs. Every other device is a *follower*: it syncs flags, folders and new UIDs with the
   provider itself, as now, but reads message content from the shared folder. New mail it sees before
   the writer has stored it is kept on that device only, until the writer's copy appears.
3. **New messages get content-derived ids**, so if two devices ever do write the same message at the
   same time (a lease handed over while iCloud lags), they write the same path with the same bytes
   and nothing is duplicated. The lease saves work; the content ids keep it safe.
4. **The index stays per device and is rebuilt from the `.md` files**, not the `.eml` files. The
   derived Markdown gets the few headers the index and classifier need (schema 2), so a device can
   index and classify without downloading any original. Originals download when opened, from iCloud
   or, if iCloud can't deliver, from the provider.
5. **Shared metadata never conflicts by construction where it can't merge**: rules, corrections,
   sender rules and preferences go in one file *per device* (each device writes only its own),
   merged by record id with a hybrid clock. Spaces, drafts and `account.json` stay one file per record
   and are merged from iCloud's conflict versions with fixed rules. Deletions are tombstones.
6. **CloudKit is dropped** for metadata: one sync mechanism, the folder. GKM-026 becomes "shared
   metadata in the iCloud Drive folder"; the rest is split into new cards (end of this page).
7. **Migration copies, verifies, and keeps the old folder** until iCloud reports every file uploaded,
   then asks before removing it. Resumable from a manifest; the existing index and sync state are kept,
   so nothing is downloaded again.

The cost: Sil's mailbox would put **about 10 GB** into iCloud when fully downloaded (3 GB today), and
Apple can read it unless Advanced Data Protection is on.

## What the code does today (the starting point)

- `StoreLocations` (`swift/GitKittieMailKit/Sources/MailStore/StoreLocations.swift`) has two roots:
  `mailFolder` (`Documents/Mail`) and `deviceFolder` (`Application Support/Mail`). The mail folder
  holds `layout.json`, `accounts/<id>/account.json`, `accounts/<id>/messages/<yyyy>/<mm>/<id>.eml|.md`,
  `blobs/<sha256>`, `spaces/<id>.json` and `drafts/<id>/`.
- The device folder holds `index.sqlite`, `state/<account>/sync.sqlite` (remote mapping, cursors,
  flags, action journal, provider deletions), `state/journal/`, `state/outbox/`, `state/device-id`,
  `cache/`, `partial/`, and the user metadata that GKM-026 was to sync: `metadata/classification.json`
  (MAIL-039), `metadata/sender-rules.json` (MAIL-054), `metadata/unsubscribes.json` (MAIL-057),
  `metadata/pins.json` (MAIL-064), `preferences/notifications.json` (MAIL-085),
  `preferences/remote-images.json` (MAIL-033), `preferences/accounts.json` (account order) and
  `preferences/open-history.json`.
- `MailFolderLocation` (`swift/MailAppModel`) lets the Mac pick another mail folder through a
  security-scoped bookmark and gives it its own device folder, `folders/<hash of path>`. **Nothing
  stops a person from picking a folder inside iCloud Drive today**, and the store writes there without
  `NSFileCoordinator` and reads `.eml` files that iCloud may have evicted. That should be blocked until
  this design is built (card F below).
- `MailStore.rebuildIndex()` parses every `.eml` (`complete(id:…)`). On a device where originals are
  evicted, a rebuild would download the whole mailbox.
- Message ids are random UUIDs (`MailMessageID()`); a sync dedupes by the device's own remote mapping,
  then by Message-ID + content fingerprint with a **byte comparison** of the stored original
  (`MailStore+SyncBatch.swift`). A second device with an empty mapping would therefore download every
  body to find out it already has it.
- `DraftStore` already treats a save from a stale revision, and a sync tool's `draft 2.json`, as a
  conflict copy. iCloud Drive mostly reports conflicts as `NSFileVersion` conflict versions instead of
  sibling files, which it doesn't read yet.
- Passwords are in the data-protection Keychain, `…AfterFirstUnlockThisDeviceOnly` (MAIL-027).
  `AccountSync.start` already says "This iPhone has no password for this account yet" for an account
  that came with a folder.
- `ServerSearcher` already fetches per-message summaries (INTERNALDATE, RFC822.SIZE, flags) without
  bodies; the follower sync below reuses that.

**Sil's mailbox, measured read-only on 2026-11-26** (`du`, `find`, `stat` on
`~/Library/Containers/app.hakobs.gitmail/Data`, nothing opened):

| | Now | Full Inbox (128,952 messages, GKM-090) |
| --- | --- | --- |
| Messages | 36,119 (iCloud account) + 61 (On My Mac) | ≈129,000 |
| `.eml` | 2.64 GB (73 KB average) | ≈9.4 GB |
| `.md` | 0.16 GB (4.5 KB average) | ≈0.6 GB |
| `blobs/` | 0.17 GB, 1,732 files | ≈0.6 GB |
| Files | ≈74,000 | ≈265,000 |
| Device folder (`index.sqlite` 336 MB, cache, partial, state) | 0.39 GB | ≈1.3 GB (stays local) |

Other folders (Sent, Archive) are not in the projection. The Mac had 11 GB free when measured.

## 1. Folder layout

Container `iCloud.app.hakobs.gitmail` (the Mac and iPhone app share the bundle id `app.hakobs.gitmail`,
MAIL-070, so they share the container). On the Mac it is
`~/Library/Mobile Documents/iCloud~app~hakobs~gitmail/`; the mail folder is its `Documents/Mail`, which
shows in Finder and Files as **iCloud Drive ▸ GitKittie Mail ▸ Mail** (`NSUbiquitousContainerName`
"GitKittie Mail", not the app's display name "Mail", which would sit next to Apple Mail's).

    Documents/Mail/                                   shared, iCloud Drive
      layout.json                                     layoutVersion 2
      devices/<device-id>.json                        name, platform, app version, last seen (new)
      accounts/<account-id>/account.json              as now, plus `modified`
      accounts/<account-id>/writer.json               the writer lease (new, §2)
      accounts/<account-id>/messages/<yyyy>/<mm>/<id>.eml   original, never rewritten
      accounts/<account-id>/messages/<yyyy>/<mm>/<id>.md    derived, schema 2 (§3)
      spaces/<space-id>.json                          format 2: rule and deletion tombstones (§5)
      drafts/<draft-id>/…                             as now (MAIL-025)
      metadata/<kind>/<device-id>.json                corrections and rules, sender rules,
                                                      unsubscribes, shared preferences (§5)

    Application Support/MailCloud/<identity>/         per device, never synced
      index.sqlite                                    the index (rebuilt from .md, §3)
      state/<account-id>/sync.sqlite                 mapping, cursors, flags, journal (unchanged)
      state/journal/, state/outbox/, state/device-id  unchanged
      pending/<account-id>/                           follower: new mail the writer hasn't stored yet (new)
      partial/<account-id>/, cache/                   unchanged; cache/blobs also holds decoded
                                                      attachments (the old Mail/blobs/, see below)
      preferences/                                    device-only: open history, storage budget,
                                                      history window, which device writes is NOT here
      migration.json                                  while a migration runs (§6)

What changes in the shared folder:

- **`blobs/` leaves the shared folder.** A blob is an attachment decoded from its `.eml`
  (`MailStore.derive`), so it is derived data like the index, and uploading it doubles every
  attachment in iCloud. In layout 2 decoded attachments are a device cache, made again from the
  original when needed. Attachment integrity is unchanged: a blob is still checked against its SHA-256.
- **Metadata moves in**: the `metadata/` and the shared half of `preferences/` from the device folder.
- **`devices/`** names each device for the UI ("Written by Sil's MacBook Pro, 4 minutes ago") and
  tells tombstone clean-up which devices exist.

Stays per device: everything in `state/` (the mapping is a device's position at the provider, MAIL-020;
two devices' cursors in one file would corrupt each other), the index, the outbox (two devices must
never both own a send, MAIL-022), partial messages (GKM-036: never an original), caches, the storage
budget and history window (the iPhone's are smaller, MAIL-079), and passwords.

**The device folder is keyed by iCloud identity** (`MailCloud/<first 8 bytes of SHA-256 of the archived
ubiquityIdentityToken>`), the way `MailFolderLocation` keys a picked folder by its path. Signing in
with another Apple ID then never mixes one account's index and sync state with another's container.

## 2. One writer per account

### Why a writer at all

The store's guarantee is "a message exists when its `.eml` exists" (MAIL-018). With two devices
importing the same account into one folder, both would download every body, and (with random ids)
store each message twice. Destructive folder work, "Remove mail deleted elsewhere" (MAIL-075) and
account removal, also needs exactly one actor, or a device that has not seen the latest provider state
deletes what another device just stored.

### The lease

`accounts/<id>/writer.json`:

    { "format": 1, "device": "<device-id>", "deviceName": "Sil's MacBook Pro", "epoch": 3,
      "taken": "…Z", "renewed": "…Z" }

- **Assignment.** The device that adds an account, or migrates a folder, takes epoch 1. The other
  devices see the file and follow. The writer can be moved by hand: Settings ▸ the account ▸ "Store
  this account's mail from this Mac/iPhone" writes `epoch + 1` with this device.
- **Renewing.** The writer rewrites `renewed` every 15 minutes while its sync runs (a coordinated
  write of a few hundred bytes), and before each stored batch it reads the file again (a local read)
  and stops writing if another device holds a higher epoch.
- **Expiry.** A lease is *stale* when `renewed` is more than 72 hours old. Stale changes what the
  followers say ("Your Mac last stored mail 3 days ago"), and whether a follower takes over is
  Sil's question 2: recommended is never automatically, with a "Take over" button.
- **Two devices both think they hold it** (iCloud delivered the hand-over late, or both wrote
  `writer.json` while offline, which iCloud reports as a conflict). Highest epoch wins; equal epochs,
  the smaller device id. The loser stops writing as soon as it reads the merged file. What both wrote
  meanwhile is safe because of content ids (below).
- **The writer is offline or asleep.** Nothing stops. Followers keep showing new mail from their own
  pending copies (below) and say when the writer last stored mail. When the writer returns it syncs
  from the provider as it always has; its cursors are its own.

iCloud Drive has no compare-and-swap, so the lease can't be a hard lock. It doesn't need to be: it
decides who *should* write, and content ids make a double write harmless.

### Content-derived message ids

New messages get a UUID derived from the account and the original's SHA-256 (UUID version 8, the
first 16 bytes of `SHA-256("gkm-message-v1\n" + account id + "\n" + eml sha256)`, with the version and
variant bits set). `MailMessageID(_:)` already accepts any well-formed UUID, so readers don't change.
The month folder comes from the received date, the provider's INTERNALDATE, the same on every device.
Two devices storing the same message write the same `.eml` with the same bytes; iCloud's conflict, if
it reports one, has identical versions and is resolved by keeping either. The 36,000 messages already
stored keep their random ids; they are never written again.

### What a follower does

A follower runs the sync it runs now with one change: it does not write originals into the shared
folder.

1. **Folders, flags, new UIDs** from the provider, into its own `sync.sqlite`, as now. Its action
   journal replays to the provider as now (MAIL-034, MAIL-035: the provider wins), so read, flag,
   move and archive work on every device without asking the writer.
2. **Matching instead of downloading.** For a UID it doesn't know, it fetches the summary
   `ServerSearcher` already fetches (INTERNALDATE, RFC822.SIZE, flags) and the Message-ID header, and
   looks the message up in its index by account + Message-ID + size + received date (all in the `.md`
   front matter). One match: it records the location against that id, no body fetched. No match or
   more than one: as below.
3. **New mail the writer hasn't stored** (the Mac is asleep, or simply slower): the follower fetches
   it within its own budget and window and keeps it in `pending/<account>/`, a device-only store like
   `partial/`, shown and searchable at once. It computes the content id from the bytes; when a file with
   that id (or a matching Message-ID + size + date) appears in the shared folder, the pending copy is
   dropped and its location moves over. It never moves pending mail into the shared folder itself.
4. **No destructive folder work.** "Remove mail deleted elsewhere" and removing an account's files run
   only on the writer. A follower that removes an account removes it from *this device* (its password,
   its sync state) unless the person chooses "Remove from every device", which asks the writer to do it
   (a request file) or, with the writer stale, offers to take the lease first.

Offline, a follower shows what it has and queues actions, as now.

## 3. The index stays per device

The index is already device state rebuilt from the folder (MAIL-005, MAIL-013); it stays in the
device folder, never in iCloud (SQLite in iCloud Drive corrupts).

- **Rebuild from `.md`, not `.eml`.** The derived Markdown already carries ids, addresses, subject,
  dates, threading headers, `emlSha256`, `emlSize` and the attachment list. Schema 2 adds the headers
  the index and the classifier read and don't keep now: List-Id, List-Unsubscribe,
  List-Unsubscribe-Post, Authentication-Results and the rest of the classifier's header inputs (an
  explicit list, `DerivedMarkdown.indexedHeaders`). With that, `rebuildIndex` and classification run
  from `.md` alone; `complete(id:)` re-derives from the `.eml` only when the `.md` is missing, older
  than schema 2, or its `emlSha256` doesn't match. The migration writes schema 2 for every message it
  copies (§6), so the shared folder starts complete.
- **What a device indexes** is a choice of months: the month folders are named by received date, so
  the iPhone picks the months inside its history window from paths, without reading anything. The Mac
  indexes everything.
- **Live changes** come from an `NSMetadataQuery` over the container (scope
  `NSMetadataQueryUbiquitousDocumentsScope`, predicate on `.md`, limited by path prefix on iPhone):
  added and changed `.md` files are indexed in batches, removed ones leave the index. The index records
  per message whether its original is here (`downloaded`, `evicted`, `downloading`) from the query's
  `ubiquitousItemDownloadingStatus`.
- **Attachment text** for search (MAIL-031, MAIL-052) needs the attachment's bytes, so it exists only
  for messages whose original is on that device. Search says so when results may be incomplete.
- **What can't be shared** stays device-local and is rebuilt: thread ids, `space_members`, verdicts
  (rebuilt from the classifier and the shared corrections), the overlay of open actions.

## 4. Eviction and downloads

iCloud Drive may replace any file with a placeholder: always on iPhone for files the app hasn't asked
for, and on a Mac with "Optimize Mac Storage" on when space runs low. The store has to treat an absent
original as normal on both.

- **Every read and write in the shared folder is coordinated** (`NSFileCoordinator`, batched with
  `coordinate(with:queue:byAccessor:)` for a sync batch). The atomic write stays (stage, flush, rename);
  the staging file is named `<name>.nosync` in the same folder, so iCloud never uploads a half-written
  file (to verify in spike A).
- **Opening a message** whose original is evicted starts `startDownloadingUbiquitousItem(at:)` and
  shows the `.md` text at once (it is already there: the device indexed it). If the download hasn't
  finished in 10 seconds or iCloud is unreachable, the follower fetches the message from the provider
  by its UID (it has the mapping), into `cache/`, checked against `emlSha256`. Same for Forward, export
  and Save As, which need the original.
- **What the iPhone downloads when the Mac already has the history:** nothing but `.md` files inside
  its history window (`AccountServices.historyDays`, 14 days by default, MAIL-079; older months on
  "Download Older Mail" within the history budget), the `account.json` and metadata files, and an
  original only when it is opened, pinned or forwarded. With the 14-day window that is a few MB of
  `.md`, against the 9.4 GB of originals. Older mail is found by search (the index's months, then
  "On the server", MAIL-081, whose results now open from iCloud when the folder has them).
- **Budgets.** Downloaded iCloud files count against the phone's storage, not the app's cache. The
  iPhone keeps its budget by calling `evictUbiquitousItem(at:)` on originals it downloaded and hasn't
  opened in 30 days, outside pins, least recently used first. Eviction never deletes: the file stays in
  iCloud. The 250 MB cache (MAIL-079) keeps covering the device-only `cache/` and `pending/`.
- **Pins** mean "keep this downloaded here": the app downloads what a pin covers and doesn't evict it
  itself. macOS can still evict under pressure and there is no public API to stop it, so each sync pass
  downloads pinned originals again if they went. Whether a pin applies on every device is question 6.
- **Integrity.** The store's hash check (`integrityReport`) skips evicted originals and says how many
  it skipped; it never downloads the mailbox to check it.
- **The writer evicted.** A Mac writer with Optimize Mac Storage on loses local originals, which is
  fine: its mapping already knows those messages, and it never needs an original to sync.

## 5. Conflicts and merge rules

Two kinds of shared files:

**One file per device** (each device writes only its own, so iCloud never sees two writers):
`metadata/<kind>/<device-id>.json` for `classification` (corrections and rules, MAIL-039),
`sender-rules` (MAIL-054), `unsubscribes` (MAIL-057), `pins` (if shared, question 6) and
`preferences` (the shared half, question 7). Each holds the records this device changed last:

    { "format": 1, "device": "<device-id>", "records": [
        { "id": "<uuid>", "clock": "2026-11-26T14:03:11.204Z/0007/<device-id>", "deleted": false, …record… } ] }

- **Merge:** for each record id, the version with the highest hybrid logical clock (wall time, a
  counter that keeps it ahead of every clock this device has seen, then the device id) wins, across
  every device's file. Deterministic on every device in any order.
- **Delete** writes the record with `deleted: true` (a tombstone). Tombstones older than 180 days are
  dropped once every device in `devices/` has been seen after them.
- **Ordered lists** (sender rules are one ordered list, MAIL-055) carry a fractional `order` key per
  record, so reordering is a change to one record.
- **Manual beats automatic** (Architecture, Multi-device sync): a correction always beats a verdict,
  which is per device anyway.
- A device rewrites its own file after a 2-second pause in changes, and drops records another device
  has since superseded, so files stay small.

**One file per record** (any device may write it; merged from iCloud's conflict versions,
`NSFileVersion.unresolvedConflictVersionsOfItem`, then the others marked resolved):

| File | Merge |
| --- | --- |
| `spaces/<id>.json` | Scalars (name, icon, colour, order): newer `modified`. `members` and `excluded`: union by `message`; a message in both stays excluded if its `excluded.added` is at least its `members.added`. Rules: union by rule id; format 2 adds `removedRules: [{id, at}]` so a deleted rule stays deleted. A deleted space becomes `{format: 2, id, deleted}`; an edit newer than the deletion brings it back (no edit is lost), an older one doesn't. |
| `drafts/<id>/draft.json` | As now (MAIL-025): a version from another revision becomes a conflict copy, never merged. `DraftStore` also adopts `NSFileVersion` conflicts, not only `draft 2.json`. |
| `accounts/<id>/account.json` | Newer `modified` wins for the whole file (settings change rarely); the other version's changed fields are listed in the sidebar's notice for a week. |
| `accounts/<id>/writer.json` | Highest epoch, then smaller device id (§2). |
| `.eml` | Identical bytes: keep one. Different bytes under one id should be impossible; if it happens, the version matching the `.md`'s `emlSha256` stays and the other is stored as a new message. Nothing is dropped. |
| `.md` | Derived: re-derive from the `.eml`. |
| `layout.json`, `devices/*.json` | Any (identical, or one device's own). |

A file iCloud can't deliver or that won't decode is listed in the sidebar's notice and left alone, as
spaces already are.

**What stays per device** without question: open history and last place, storage budget and history
window, the outbox, and everything in `state/`.

## 6. Migrating Sil's Mac

The Mac has 36,180 messages in `~/Library/Containers/app.hakobs.gitmail/Data/Documents/Mail` (2.9 GB)
and its device state beside it. Requirements: no data loss, resumable after a quit, crash or reboot,
and nothing downloaded from the provider again.

1. **Preflight.** iCloud Drive is on for the app (`url(forUbiquityContainerIdentifier:)` returns a URL,
   `ubiquityIdentityToken` is set); free disk is at least the folder's size plus 2 GB (now: 2.9 + 2 GB of
   11 GB). iCloud's free quota can't be read through a public API, so the sheet states the size ("About
   3 GB now, about 10 GB once all your mail is downloaded") and the person confirms. Every account's
   sync and the outbox's processing stop; mail stays at the provider meanwhile.
2. **Manifest.** `migration.json` in the device folder lists the units in order: `layout.json`, each
   `account.json`, `spaces/`, `drafts/`, the metadata files, then each `messages/<yyyy>/<mm>` folder
   (one unit per month: 13 years ≈ 150 units), each with its file count and state.
3. **Copy each unit** with coordinated writes into `Documents/Mail/.migrating/<unit>` in the
   container (a `.nosync` folder: not uploaded yet). For messages, each `.eml` is copied byte for byte
   and checked against its `.md`'s `emlSha256`; the `.md` is re-derived as schema 2. A mismatch stops
   the unit and is reported; that message stays in the old folder only. A finished unit is renamed into
   place and marked done in the manifest.
4. **Metadata** from the device folder (`classification.json`, `sender-rules.json`,
   `unsubscribes.json`, `pins.json`, the shared preferences) is written as this device's
   `metadata/<kind>/<device-id>.json`, with every record clocked now. Blobs go to the device cache,
   not the shared folder (§1).
5. **Switch.** This Mac takes every account's lease (epoch 1). The device folder is renamed (same
   volume, one rename) from `Application Support/Mail/` to `Application Support/MailCloud/<identity>/`, so the index, the mapping, cursors, journal and outbox
   are kept: the index stores paths relative to the mail folder, so it is still valid. The store opens on
   the new location and syncs again.
6. **Resume.** On launch, an unfinished `migration.json` continues at its first unit that isn't done;
   a half-copied `.migrating/<unit>` is deleted and copied again. Until the switch, the old folder is
   the one in use, so a stop at any point before step 5 leaves the app exactly as it was.
7. **Keep the old folder** read-only (the app no longer opens it) until the `NSMetadataQuery` reports
   every file in the shared folder uploaded (`ubiquitousItemIsUploaded`). Then Settings ▸ Storage offers
   "Remove the old copy on this Mac (2.9 GB)". It is never removed without that click.

Moving instead of copying (`FileManager.setUbiquitous(true, itemAt:destinationURL:)`) needs no extra
space, but until iCloud has uploaded everything, turning iCloud Drive off and choosing "Remove from
Mac" deletes the only copy. That is question 4.

**The iPhone joins** rather than migrates. Its own `Documents/Mail` holds 14 days that the provider and
the Mac also have.

- Each of its accounts is matched to an account in the shared folder by provider host and user name,
  shown to the person ("Your iCloud account on this iPhone is the same as on the Mac"), and on OK the
  iPhone takes the shared account's id: the Keychain item is written under that id and its old sync
  state is set aside. No match: the account joins the folder as is, with the iPhone as its writer.
- Its drafts are copied into the shared `drafts/` (ids are UUIDs, no clashes); its outbox stays.
- It builds a new device folder and index from the shared `.md` files in its window.
- Its old local folder is kept until the person removes it in Settings ▸ Storage.

## 7. App Store, quota and failure modes

**Entitlements** (in `project.yml` for both apps, never in the Xcode project):

- `com.apple.developer.icloud-container-identifiers: [iCloud.app.hakobs.gitmail]`
- `com.apple.developer.icloud-services: [CloudDocuments]` (no `CloudKit` if MAIL-122 is accepted)
- `com.apple.developer.ubiquity-container-identifiers: [iCloud.app.hakobs.gitmail]`
- Info.plist `NSUbiquitousContainers`: `{ iCloud.app.hakobs.gitmail: { NSUbiquitousContainerIsDocumentScopePublic: true, NSUbiquitousContainerName: "GitKittie Mail", NSUbiquitousContainerSupportedFolderLevels: Any } }`

The container has to be registered on the developer account and added to the app id's iCloud
capability, through the `_appstore` hub (fastlane `produce`, to verify in spike A) rather than Xcode.

**App Review and privacy.** Files in the person's own iCloud Drive are not "collected" by the developer,
so the privacy label stays "Data Not Collected". The privacy policy and the opt-in text must say mail is
stored in iCloud Drive and that, without Advanced Data Protection, Apple holds the keys. That is a new
party for Gmail and other IMAP mail (ThreatModel.md needs a section, card H). Apple's storage guidance
is about device backups, not iCloud Drive documents the person chose; offering iCloud Drive as an
explicit choice (question 9) keeps review simple. Re-downloadable data in iCloud is the person's choice
here, and the app never puts caches or the index there.

**Quota.** Sil's mailbox: ≈3 GB now, ≈10 GB with the whole Inbox (`.eml` 9.4 GB + `.md` 0.6 GB; blobs
stay off iCloud), more with Sent and Archive. That needs a 50 GB plan at least, and counts against what
the family shares. The first upload is about 265,000 files; iCloud Drive is slow with many small files,
so expect hours to a day or more (not measured; spike A measures it). The Mac's disk use doesn't grow:
the folder moves from the container to iCloud Drive, both on the Mac.

**Failure modes**

| What happens | What the app does |
| --- | --- |
| iCloud Drive off for the app, or signed out at launch | No container URL. Sync pauses (mail stays at the provider), the window says "Mail's folder is in iCloud Drive, which is off on this Mac" with Open Settings, and offers "Use a folder on this Mac instead" (a reverse migration from what is downloaded, then the provider fills the gaps). |
| Signed out while running (`NSUbiquityIdentityDidChange`) | Stop the store at once; the files may be removed from the Mac by the sign-out. The index is set aside, not used against a folder that is gone. |
| Another Apple ID | Another container, another `MailCloud/<identity>` device folder; nothing is mixed. |
| Quota full | Uploads stop with an error on each file (`ubiquitousItemUploadingError`); the files stay on the writer, so nothing is lost, but followers don't get them. Settings ▸ Storage: "iCloud storage is full: 1,240 messages are only on this Mac." Followers keep pending copies. |
| Mac disk nearly full | GKM-090's pause (below 2 GB) applies to the writer; with Optimize Mac Storage, macOS evicts uploaded originals first. |
| A file deleted in Finder or Files | It leaves the index everywhere. The writer's mapping still lists it; on its next pass the writer downloads it again from the provider if it is still there (a repair), else it is gone. iCloud keeps deleted files 30 days in Recently Deleted. |
| iCloud slow or down | Originals open from the provider (§4); new mail lands in pending; sync with the provider is unaffected. |
| Writer lost for good (Mac sold) | Lease stale after 72 hours; a follower takes over by the button (or automatically, question 2). |

## 8. What changes in the cards

**GKM-026** loses CloudKit: no `CKSyncEngine`, no records. Its outcome stays (spaces, rules,
corrections, notes, preferences and pins converge across devices without loss), done through the shared
folder (§5). It keeps "explicit account mapping across devices" (§6, the join), "conflict rules,
offline edits" and "iCloud unavailable" (§7). Acceptance "no message body is ever in a CloudKit record"
becomes "nothing device-specific (index, sync state, outbox, passwords) is ever in the shared folder".
Proposed title: "Sync spaces, rules and corrections through the shared iCloud Drive folder". It becomes
card E below and depends on B.

**GKM-028** (outbox and drafts across devices) gets simpler and sharper. The outbox stays device-local
(MAIL-022). Drafts are already in the shared folder (MAIL-025); what's new:

- `DraftStore` adopts `NSFileVersion` conflict versions as conflict copies (iCloud rarely makes
  `draft 2.json`).
- **One send per draft:** the device that sends first claims the draft at the provider, where a real
  compare-and-swap exists: the draft is appended to the provider's Drafts folder with its stable
  Message-ID, and the sender sets a `$GitKittieSending` keyword with `UID STORE … (UNCHANGEDSINCE
  <modseq>)` (CONDSTORE, RFC 7162; iCloud, Gmail and Dovecot have it). Only one device's STORE succeeds;
  the other says "Sent from your Mac". Without CONDSTORE, the outbox's existing Message-ID search of
  Sent before sending narrows the window to seconds. Needs a spike against the test server.
- Depends on B (coordinated access) instead of on the CloudKit work.

**Other cards touched:** GKM-027 (iPhone app): MAIL-051's "no iCloud Drive on iOS" is superseded by
MAIL-120 once built; its storage budget applies to downloads (§4). GKM-090/GKM-091: the disk pause
applies to the writer. GKM-032 (archive sync) is partly answered: the shared folder *is* a synced
archive; its encryption question remains.

### Proposed implementation cards

To be filed after Sil's OK, in this order. Letters, not ids, until then.

| | Card | Priority | Needs |
| --- | --- | --- | --- |
| A | Spike: iCloud Drive container on Mac and iPhone (entitlements via the hub, 265k-file `NSMetadataQuery` cost, `.nosync` staging + coordinated rename, eviction and download, conflict versions, quota error, sign-out) | P1 | — |
| B | Store: a mail folder in iCloud Drive: layout 2 (blobs to the device cache, `.md` schema 2), coordinated reads and writes, originals on demand with provider fallback, index rebuild from `.md`, `NSMetadataQuery` watcher, device folder per iCloud identity, content ids for new messages | P1 | A |
| C | Writer lease and follower sync: `writer.json`, hand-over UI, matching by Message-ID + size + date, `pending/` | P1 | B |
| D | Migrate a local mail folder into iCloud Drive (resumable, copy-verify-keep), and the iPhone's join with account mapping | P0 (data safety) | B, C |
| E | = GKM-026, rescoped: shared metadata (per-device files, hybrid clock, tombstones), spaces format 2, `account.json` conflicts; two-device convergence tests | P2 | B |
| F | Failure modes and Settings ▸ Storage for iCloud (off, signed out, identity change, quota, waiting to upload, old copy removal). Before any of this: refuse or warn when a picked mail folder is inside iCloud Drive (can ship now) | P1 | B |
| G | = GKM-028, rescoped: drafts through iCloud conflict versions, one send per draft via CONDSTORE | P1 | B |
| H | Docs and launch: Architecture.md and ThreatModel.md (Apple as a party, ADP), privacy policy, App Store container through the hub | P1 | A |

**Verification** for the set: two real devices (Sil's Mac and the iPhone 14 Pro test device) on one
Apple ID, plus the GreenMail server: offline edits on both converge; a lease hand-over during a sync
stores no message twice; the migration killed at random points resumes to a byte-identical folder;
iCloud turned off mid-sync loses nothing.

## Trade-offs

For:

- What Sil asked for: one folder, visible in Finder and Files, the same on every device; the iPhone
  can read the Mac's whole history without asking the provider.
- One sync mechanism for mail and metadata instead of files plus CloudKit.
- The existing per-device state, journal and outbox guarantees carry over unchanged.

Against:

- ≈10 GB of Sil's iCloud plan, and a slow first upload of a quarter of a million files.
- Apple can read the mail unless Advanced Data Protection is on; with CloudKit's encrypted fields the
  metadata could have been end-to-end encrypted regardless.
- Real work: coordination, eviction handling, the follower sync and the migration are four cards of
  careful code where the per-device design needed none. Every read of an original can now wait on iCloud.
- iCloud Drive gives no lock and no ordering, so correctness rests on content ids, per-device files and
  deterministic merges rather than a server. Each of those has to be tested on real devices.
- People who don't use iCloud Drive get no metadata sync if CloudKit is dropped (question 5).

Rejected along the way:

- **Every device writes what it syncs, no lease.** Content ids would prevent duplicates, but both
  devices would download every body, iCloud would see constant identical-write conflicts, and nobody
  would own "Remove mail deleted elsewhere".
- **Sharing the remote mapping or `sync.sqlite`** so followers needn't match. SQLite in iCloud Drive
  corrupts; a JSON ledger of 129,000 UIDs per folder rewritten on every pass would churn iCloud; and the
  mapping is a device's own position at the provider (MAIL-020).
- **Indexing from `.eml`** on followers: downloads the mailbox.
- **Keeping `blobs/` in the shared folder:** pays for every attachment twice in iCloud.

## Questions for Sil

Asked in review `GitKittie/review/GKM-026-icloud-drive-design`, each with a recommended answer:

1. Build it this way (MAIL-120..122)?
2. When the Mac hasn't stored mail for three days, does the iPhone take over? (Recommended: no, it
   keeps new mail on itself and offers "Take over".)
3. What does the iPhone keep from the shared folder? (Recommended: its 14-day window; older mail opens
   from iCloud when searched or asked for.)
4. Migration: copy and keep the old folder until iCloud has it all, or move? (Recommended: copy, needs
   3 GB free now.)
5. Drop CloudKit for metadata? (Recommended: yes; people with a local folder get no metadata sync for
   now.)
6. Pins: on this device only, or every device? (Recommended: this device.)
7. Which preferences follow you? (Recommended: account order, notifications and remote images follow;
   storage, history window and last place stay per device.)
8. Passwords: typed once on each device, or synced through iCloud Keychain? (Recommended: once per
   device.)
9. For new users from the App Store: iCloud Drive by default, or a choice? (Recommended: "On this
   device" by default, iCloud Drive offered at setup.)
