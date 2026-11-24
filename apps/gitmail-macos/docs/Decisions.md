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
| MAIL-016 | Gmail at first release connects over IMAP with an app password, through the IMAP adapter; OAuth is added later only as a different sign-in on the same connections | No verification or yearly assessment needed; reaches most personal Gmail accounts. Proposed by GKM-008 (ProviderAccess.md), 2026-11-24. **Needs Sil** |

Decided by Sil on 2026-11-24 (GKM-001), through the review `GitKittie/review/GKM-001-mail-decisions` on the board:

- **Fit with GitKittie:** Git optional, iCloud for metadata, as proposed (MAIL-002). GitKittie Mail is a GitKittie app; on the site it is described by the files you own, not by Git.
- **Providers:** iCloud, any IMAP account and Gmail at first release (MAIL-014). This makes the Gmail cost (GKM-008) a launch question and moves the Gmail adapter (GKM-029) to Phase 2.
- **Pricing:** decided after the MVP tests (MAIL-012).
- **Code:** in the gitkittie monorepo (MAIL-015).

GKM-008 answered the Gmail cost question on 2026-11-24 (details and sources in ProviderAccess.md):

- Every Gmail OAuth scope that can read mail is restricted. That means Google's restricted-scope verification plus a third-party security assessment (CASA) every 12 months. Reported prices: about US$540–1,800 a year at the lower tier, US$4,500–8,000+ at the higher one. Google picks the tier.
- A local-only design probably does not avoid the assessment: Google's pages disagree, and a 2026 report says Google required it for a local-only app.
- Gmail with an app password (IMAP, 2-Step Verification) needs no verification and costs nothing, but is unavailable for security-key-only, Advanced Protection and some work accounts.

**Go/no-go, needs Sil before Phase 2:**

1. Accept MAIL-016: Gmail at first release via IMAP and app password (recommended: go).
2. Decide whether to fund Gmail OAuth (restricted-scope verification and the yearly assessment, two to three months lead time). If the higher tier's cost cannot be carried by a one-time price, Gmail stays app-password only, or OAuth needs its own pricing; this links to MAIL-012.

Open technical questions: audit maintained Swift-compatible IMAP/SMTP/MIME libraries and licences; validate provider OAuth scope/approval and quotas; prototype encrypted CloudKit metadata, identity mapping and archive key recovery; determine local history/attachment storage budgets and iOS file access; measure multilingual classifier accuracy and set release thresholds; choose shared package names after repo audit; validate pricing and relay demand; complete threat model, privacy, accessibility and App Store review before launch.
