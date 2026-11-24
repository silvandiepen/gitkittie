# Decisions

Proposed, subject to validation.

| ID | Decision | Rationale |
| --- | --- | --- |
| MAIL-001 | Existing providers authoritative for live mail | No migration, interoperability |
| MAIL-002 | Git optional | Privacy, deletion, attachment size |
| MAIL-003 | EML originals, derived Markdown, separate mutable state | Readability without losing MIME |
| MAIL-004 | Individual messages, reconstructed threads | Preserve reply relationships |
| MAIL-005 | Rebuildable SQLite FTS5 | Search without lock-in |
| MAIL-006 | Provider + metadata + archive sync layers | Avoid competing authorities |
| MAIL-007 | Virtual mode default | Safe onboarding |
| MAIL-008 | Separate purpose, urgency and risk | Marketing is not inherently spam |
| MAIL-009 | Local classifier, optional AI | Privacy and predictable cost |
| MAIL-010 | Opt-in cleanup, no suspicious auto-unsubscribe | Protect mail and address |
| MAIL-011 | macOS first | Validate reliability before mobile push |
| MAIL-012 | One-time purchase preferred | Pricing unvalidated |
| MAIL-013 | Index, cache and sync cursors in Application Support, outside the mail folder | Per-device state; a synced or versioned folder must never carry them |
| MAIL-014 | iCloud (IMAP/SMTP with an app-specific password) is the first and only provider until Phase 4 | No OAuth verification needed; proves the core before paying for provider approval |

Open questions for Sil, before Phase 1 (GKM-001):

- **Fit with GitKittie.** Every other GitKittie app keeps its data in the user's own git. Mail makes Git optional and syncs metadata through the user's iCloud (CloudKit). Is that still a GitKittie app, and how is it described next to Folder, Tasks and Bud?
- **Gmail and Microsoft cost.** Gmail's mail scopes (Gmail API and IMAP with OAuth) are restricted: Google's OAuth verification, and possibly a paid third-party security assessment depending on where mail data goes, renewed yearly. Microsoft needs publisher verification and admin consent in many organisations. Both weigh against a one-time price and are costed in GKM-008 before Phase 4 is committed to.
- **Where the code lives.** Docs stay in `apps/gitmail-macos/docs` (the existing per-app structure); the app and the shared package are created in GKM-009 after the package audit.

Open technical questions: audit maintained Swift-compatible IMAP/SMTP/MIME libraries and licences; validate provider OAuth scope/approval and quotas; prototype encrypted CloudKit metadata, identity mapping and archive key recovery; determine local history/attachment storage budgets and iOS file access; measure multilingual classifier accuracy and set release thresholds; choose shared package names after repo audit; validate pricing and relay demand; complete threat model, privacy, accessibility and App Store review before launch.
