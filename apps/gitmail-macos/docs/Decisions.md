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

Open questions: audit maintained Swift-compatible IMAP/SMTP/MIME libraries and licences; validate provider OAuth scope/approval and quotas; prototype encrypted CloudKit metadata, identity mapping and archive key recovery; determine local history/attachment storage budgets and iOS file access; measure multilingual classifier accuracy and set release thresholds; choose shared package names after repo audit; validate pricing and relay demand; complete threat model, privacy, accessibility and App Store review before launch.
