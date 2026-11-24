# Decisions

Proposed, subject to validation.

| ID | Decision | Rationale |
| --- | --- | --- |
| MAIL-001 | Existing providers authoritative for live mail | No migration, interoperability |
| MAIL-002 | Git optional; metadata syncs through the user's own iCloud (CloudKit) | Privacy, deletion, attachment size. Confirmed by Sil, 2026-11-24 |
| MAIL-003 | EML originals, derived Markdown, separate mutable state | Readability without losing MIME |
| MAIL-004 | Individual messages, reconstructed threads | Preserve reply relationships |
| MAIL-005 | Rebuildable SQLite FTS5 | Search without lock-in |
| MAIL-006 | Provider + metadata + archive sync layers | Avoid competing authorities |
| MAIL-007 | Virtual mode default | Safe onboarding |
| MAIL-008 | Separate purpose, urgency and risk | Marketing is not inherently spam |
| MAIL-009 | Local classifier, optional AI | Privacy and predictable cost |
| MAIL-010 | Opt-in cleanup, no suspicious auto-unsubscribe | Protect mail and address |
| MAIL-011 | macOS first | Validate reliability before mobile push |
| MAIL-012 | Pricing is decided after the MVP tests (GKM-024); a one-time purchase is the option to test first | No data yet; Gmail's yearly costs (GKM-008) feed into it. Decided by Sil, 2026-11-24 |
| MAIL-013 | Index, cache and sync cursors in Application Support, outside the mail folder | Per-device state; a synced or versioned folder must never carry them |
| MAIL-014 | First release supports iCloud, any standard IMAP account, and Gmail. iCloud is built first; Microsoft comes later | Reach: most people overwhelmed by marketing mail use Gmail. Decided by Sil, 2026-11-24 |
| MAIL-015 | Code lives in the gitkittie monorepo: apps/gitmail-macos (later -ios) and a shared package under swift/ | Shares GitKittieUI, GitPont and CI with the other apps. Decided by Sil, 2026-11-24 |
| MAIL-016 | A message exists when its `.eml` exists. Writes go journal → blobs → `.md` → `.eml` → index → mapping, each file staged, fsynced and renamed; the next open finishes or undoes an interrupted write from the journal (`<Application Support>/Mail/state/journal/`) | One recovery path for crashes and errors; the original is the commit point, everything else is derived. GKM-005 |
| MAIL-017 | The `.md` front matter is YAML in JSON-compatible flow form, one key per line | Any YAML reader takes it; the store reads it back exactly without a YAML dependency. GKM-005 |
| MAIL-018 | The IMAP mapping (mailbox + UIDVALIDITY + UID → local id) lives in `<Application Support>/Mail/state/<account-id>/sync.sqlite`, not in the folder | It is a device's position at the provider, like the cursors (MAIL-013); losing it costs a reconciliation pass by Message-ID and fingerprint, not mail. GKM-005 |
| MAIL-019 | The app's default mail folder is `Documents/Mail` in its container; choosing another folder comes with account setup | Works in the sandbox with no prompt; a user-chosen folder needs a security-scoped bookmark. GKM-009 |

Decided by Sil on 2026-11-24 (GKM-001), through the review `GitKittie/review/GKM-001-mail-decisions` on the board:

- **Fit with GitKittie:** Git optional, iCloud for metadata, as proposed (MAIL-002). GitKittie Mail is a GitKittie app; on the site it is described by the files you own, not by Git.
- **Providers:** iCloud, any IMAP account and Gmail at first release (MAIL-014). This makes the Gmail cost (GKM-008) a launch question and moves the Gmail adapter (GKM-029) to Phase 2.
- **Pricing:** decided after the MVP tests (MAIL-012).
- **Code:** in the gitkittie monorepo (MAIL-015).

Still open, and owned by GKM-008: what Google's restricted-scope verification and any security assessment cost each year for a local-first client. If that cost cannot be carried, the Gmail decision comes back to Sil before Phase 2.

Open technical questions: audit maintained Swift-compatible IMAP/SMTP/MIME libraries and licences; validate provider OAuth scope/approval and quotas; prototype encrypted CloudKit metadata, identity mapping and archive key recovery; determine local history/attachment storage budgets and iOS file access; measure multilingual classifier accuracy and set release thresholds; choose shared package names after repo audit; validate pricing and relay demand; complete threat model, privacy, accessibility and App Store review before launch.
