# Archive sync via user-chosen storage (GKM-032 report)

**Recommendation: don't build it now. Later, after the shared iCloud Drive folder (GKM-026) ships,
and then only as scheduled full encrypted archives into a folder the person picks** (MAIL-130). No
incremental encrypted repository. Nothing on this page is built; the encrypted archive it builds on
is (Architecture.md, "Spaces and export", "Encrypted archive"; MAIL-128, MAIL-129).

## The question

Architecture.md planned three layers: the provider for live mail, metadata sync, and an archive that
outlives provider deletion, with "portable encrypted export first, encrypted archive sync or
user-selected shared storage later". Export now exists. This page asks whether GitKittie Mail should
also keep an encrypted archive up to date somewhere the person chooses (an iCloud Drive folder, an
external disk, a NAS share, a Dropbox folder) without them making one by hand.

## What changed since that plan

Sil decided on 2026-11-26 (review GKM-042-followups, design in `iCloudDriveDesign.md`, PR #79) that
the Mac and iPhone share **one mail folder in iCloud Drive**. That folder already is
"user-selected shared storage" for the mail itself: every device reads and writes it, and its
originals are never rewritten. So archive sync is no longer how mail reaches a second device. What
it could still add:

1. **A copy that a mistake in the live folder doesn't reach.** Sync is not backup: a bad migration,
   a bug that deletes files, or "Remove mail deleted elsewhere" run by the writer reaches every
   device through the shared folder. An archive written at a point in time doesn't change after.
2. **A copy Apple can't read** for people without Advanced Data Protection, and a copy off Apple's
   storage altogether.
3. **A copy for people who don't use iCloud**, on a disk or share of their own.

## What the person already has without it

- **Encrypted Archive export** (GKM-032): File ▸ Export Encrypted Archive… writes one file of
  everything, which the person can put anywhere, including the folder they'd sync to. It covers
  1, 2 and 3 whenever they make one.
- **Time Machine**, where it is on: the app container (mail folder and device folder) is in backups
  unless excluded (ThreatModel.md, local disk). It is versioned, so it covers 1 too; it is not
  encrypted unless the backup disk is.
- **The provider** still holds live mail; the archive layer matters for mail kept after the
  provider deleted it (MAIL-075) and for spaces, rules and corrections.

What none of these do is happen by themselves on a schedule, with old copies thinned out. That is
the gap.

## Options

| | A. Scheduled full archives | B. Incremental encrypted repository | C. Don't build |
| --- | --- | --- | --- |
| What | Every N days (or on a button) write a new `.gkmarchive` into a chosen folder; keep the last K, delete older ones | Content-addressed encrypted objects (one per message and blob) plus encrypted snapshots listing them, as restic or Borg do; each run uploads only what is new | Keep manual export |
| Reuses | The format, writer, restore and all of `EncryptedArchiveTests` | The key handling only | Everything |
| New work | A schedule (Mac only: a login item or the app's own timer while open), a folder bookmark, retention, a status line, "last archive failed" notices, key handling for unattended runs | A repository format with its own index, snapshot and pack files, garbage collection of unreferenced objects, locking against two devices writing, verification, partial restore | None |
| Size | One mailbox per archive: Sil's projected ~10 GB each time (`iCloudDriveDesign.md`), K × that kept | ~one mailbox plus new mail; small runs after the first | – |
| Risk | Low: a complete file or none (written under a hidden name, renamed when whole) | High: a repository bug corrupts every snapshot at once; two writers need a real lock, which iCloud Drive can't give (no compare-and-swap, `iCloudDriveDesign.md` §2) | The gap stays |

**Key handling is the hard part of A.** Format 1 has one key per archive, shown once (MAIL-129). An
unattended run can't show a key and wait. A scheduled archive would need one long-lived recovery key
the person saved once, kept on the Mac (in the Keychain, `ThisDeviceOnly`) so the schedule can wrap
each new archive key with it. That is a real change in what the key protects against: someone with
the unlocked Mac can then read the key, though they can read the mail folder anyway. It is the
second question in review `GKM-032-encrypted-archive`.

## Why not now

- GKM-026 isn't built. Until it is, the mail folder isn't in iCloud Drive and its migration (which
  copies, verifies and keeps the old folder) is the bigger data-safety step. Building archive sync
  first would design against a layout that is about to change (`blobs/` leaves the shared folder,
  metadata moves in, `iCloudDriveDesign.md` §1).
- The value over manual export plus Time Machine is a schedule and retention. That is convenience
  for a P3, while option B's risk is the kind that loses every copy at once.
- iCloud quota: option A into iCloud Drive doubles or triples a 10 GB mailbox's footprint there
  (live folder plus K archives). People on 50 GB plans would hit it.

## If it is built later (option A)

Build it as a card after GKM-026 ships (GKM-106), with these rules:

- **Never inside the mail folder.** An archive written into the shared folder would be uploaded
  next to the mail it copies and would contain the previous archive in the next one. The folder
  picker refuses the mail folder and anything inside it.
- **On the Mac only, one device.** Like the writer lease (`iCloudDriveDesign.md` §2): the device
  that holds the mail writes the archives; the iPhone shows when the last one was made.
- **Reads the shared folder as the store does after GKM-026**: coordinated reads, originals that
  iCloud evicted downloaded first or the run waits (today's archive writer reads `.eml` files
  directly; an evicted placeholder must never be archived as if it were the message).
- **Retention by count** (keep the newest K, default 4) and never delete an older archive until the
  new one is complete and verified by opening it (the restore path, writing nothing).
- **Says when it fails** in Settings ▸ Storage and on the sidebar's foot, as the download pause does
  (MAIL-106); never silently skips.
- **Tests**: a run into a temporary folder and a restore of the newest; retention keeps K and keeps
  everything when a run fails; a run interrupted part way leaves the previous archives intact.

## Restore and the iCloud Drive folder today

Restore makes "Restored Mail" in a folder the person picks and offers Use Restored Mail, which goes
through Use Another Mail Folder…. Until GKM-026 ships, a mail folder inside iCloud Drive is unsafe
(GKM-103, in review, refuses picking one); the same refusal applies to a restored folder there, because Use
Restored Mail uses the same path (`AppModel.useMailFolder`).
