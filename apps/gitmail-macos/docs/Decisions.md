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
| MAIL-017 | IMAP on Apple's swift-nio-imap codec with our own session layer; SMTP and MIME are our own code (SMTP on SwiftNIO, MIME on Foundation); TLS through swift-nio-ssl with the system trust store. Adapters live in `swift/GitKittieMailProviders` (macOS 15 / iOS 18, Swift 6.2); MIME in `swift/GitKittieMailKit` (MailMIME) | Maintained, Apache-2.0, Swift concurrency, iOS-ready; we control exactly when a send becomes uncertain and how hostile MIME is bounded. Details and rejected options below. GKM-002 |
| MAIL-018 | A message exists when its `.eml` exists. Writes go journal → blobs → `.md` → `.eml` → index → mapping, each file staged, fsynced and renamed; the next open finishes or undoes an interrupted write from the journal (`<Application Support>/Mail/state/journal/`) | One recovery path for crashes and errors; the original is the commit point, everything else is derived. GKM-005 |
| MAIL-019 | The `.md` front matter is YAML in JSON-compatible flow form, one key per line | Any YAML reader takes it; the store reads it back exactly without a YAML dependency. GKM-005 |
| MAIL-020 | The IMAP mapping (mailbox + UIDVALIDITY + UID → local id) lives in `<Application Support>/Mail/state/<account-id>/sync.sqlite`, not in the folder | It is a device's position at the provider, like the cursors (MAIL-013); losing it costs a reconciliation pass by Message-ID and fingerprint, not mail. GKM-005 |
| MAIL-021 | The app's default mail folder is `Documents/Mail` in its container; choosing another folder comes with account setup | Works in the sandbox with no prompt; a user-chosen folder needs a security-scoped bookmark. GKM-009 |
| MAIL-022 | The outbox journal lives in device state (`<Application Support>/Mail/state/outbox/`), one folder per send with the exact bytes and the entry. Only a `notSent` outcome is retried automatically; an `uncertain` send is reconciled by Message-ID and otherwise waits for the person, and Send Again checks once more first, with the same Message-ID | A send is one device's commitment, never synced (GKM-028 coordinates devices). The only safe automatic resend is one the server provably did not take. GKM-014 |
| MAIL-023 | Sent copies follow a per-account policy: `providerFiles` (Gmail) never appends; `append` (generic IMAP) appends only after a Message-ID search finds none; `detect` (iCloud, until the GKM-004 run records what iCloud does) waits two minutes for the provider's copy before appending | Search-before-append makes the append idempotent across crashes; `detect` avoids guessing a provider's behaviour. GKM-014 |
| MAIL-024 | The composer is a native text editor over Markdown; the text/plain part is the Markdown as typed and the HTML part is generated with every typed character escaped. The web rich editor from Tasks is not used for mail | Quoted replies carry attacker-written text; it must never run through a script-enabled web view. Plain Markdown reads well in any client. GKM-013 |
| MAIL-025 | Drafts are files in `Mail/drafts/<id>/` with revisions; a save from a stale revision, or a sync tool's conflict file, becomes a separate draft marked as a conflict copy | The mail folder may be synced by iCloud Drive or GitKittie Folder; preserving both edits is the rule for drafts (Architecture.md, Multi-device sync). GKM-013 |
| MAIL-030 | Threads link messages in one account by Message-ID, In-Reply-To and References only (at most 100 per message); a Message-ID claimed by two different messages links nothing; the thread id is the group's smallest local id | Never subject alone (Architecture.md); a forged or reused id cannot merge conversations; incremental and rebuilt threads are identical. GKM-012 |
| MAIL-031 | Attachment text for search is extracted in `GitMailExtractor.xpc`, a sandboxed XPC service with no entitlements (no network, no files), bytes in and text out, a 20 s watchdog that ends the process, and size/page/output limits. Text is cached per blob in `<Application Support>/Mail/cache/attachment-text/` and tried once | PDF parsing is attacker input to a large engine; a crash or hang costs a helper process, never the app (ThreatModel §4). GKM-016 |
| MAIL-032 | HTML mail is shown through four independent layers: an allowlist sanitizer (MailHTML), JavaScript off with no script bridge, a content rule list plus `default-src 'none'` CSP, and a navigation guard that lets only the message document load. Links point at `x-gkm-link:<n>`; the real destination is shown before anything opens | Each layer alone stops remote loads in tests; no single bug reaches the network. GKM-012 |
| MAIL-033 | "Load remote images" is per message or per sender address, kept on this device (`preferences/remote-images.json`), ignored for any message with a sender warning; tracking pixels and CSS references are never loaded either way | The address is spoofable, so a lookalike sender cannot borrow a real sender's allowance. Moves to encrypted CloudKit metadata with GKM-026. GKM-012 |

## MAIL-017: protocol libraries (GKM-002, 2026-11-24)

Checked against the repositories on 2026-11-24. Licences are all App Store compatible; the shipping app lists them in its acknowledgements (swift-nio-ssl and swift-crypto carry BoringSSL's ISC/OpenSSL-style notices).

**IMAP: [apple/swift-nio-imap](https://github.com/apple/swift-nio-imap) 0.5.x (Apache-2.0), with our own session layer.** Apple maintains it (commits this week; 0.5.0 on 2026-11-13). It is a complete IMAP4rev1/rev2 parser and encoder with the extensions we need: IDLE, UIDPLUS (APPENDUID/COPYUID), MOVE, CONDSTORE/QRESYNC, LITERAL+, ESEARCH, ENABLE, ID, SPECIAL-USE, OBJECTID and Gmail's X-GM attributes; it streams FETCH bodies and handles synchronising literals itself. 0.5.0 fixed FETCH literal corruption and unquoted untrusted bytes in the encoder, so older versions are out, and 0.5 sets the floor at Swift 6.2 and macOS 15 / iOS 18. Its new `IMAPCommands` client is not used: it offers no custom trust roots (needed for the local test server and self-hosted servers), no STARTTLS and no command timeouts. Our `IMAPSession` (MailIMAP) drives the codec one command at a time and maps everything onto MailProvider's protocol-agnostic `MailboxSession`. Pinned to 0.5.x because 0.x minors may break the API.

**SMTP: our own client on SwiftNIO (MailSMTP).** SMTP submission is small (EHLO, STARTTLS, AUTH, MAIL/RCPT/DATA), and the outbox needs to know exactly where a transaction stopped: failures before the end-of-data marker are `notSent`, a lost reply after it is `uncertain` and must never be resent blindly (Architecture.md, Sending and drafts). No library reports that. Ours also refuses to continue without STARTTLS when it was asked for, rejects plaintext injected ahead of the TLS handshake, normalises bare CR/LF (SMTP smuggling) and validates envelope addresses. Supports implicit TLS (465), STARTTLS (587, iCloud), AUTH PLAIN, LOGIN and XOAUTH2.

**MIME: our own parser and builder on Foundation (MailMIME, in GitKittieMailKit).** No maintained Swift MIME library exists. Ours parses multipart trees, base64/quoted-printable, charsets, RFC 2047 encoded words, RFC 2231 parameters, address lists and RFC 5322 dates; it never throws on hostile input but reports problems and stops at limits (depth, part count, header size); it makes attachment names safe. The builder writes CRLF messages with encoded headers, RFC 2231 file names, QP text and base64 attachments, keeps Bcc out of the message and refuses header injection. MailStore's `MessageParsing` seam can adopt it in place of `BasicMessageParser`.

**TLS: swift-nio-ssl** for both protocols. With the default trust roots it validates through the Security framework, so it trusts exactly what the OS trusts; host names are always checked; TLS 1.2 minimum. Network.framework (swift-nio-transport-services) was the alternative, but it cannot start TLS on an open connection, which SMTP STARTTLS needs; one stack for both is simpler to audit. Revisit for IMAP on iOS if Network.framework's path handling turns out to matter (GKM-027).

**Why a separate package.** swift-nio-imap 0.5 needs Swift 6.2 and macOS 15 / iOS 18, while the app (GKM-009) and GitKittieMailKit still build for macOS 14 with Xcode 16. `swift/GitKittieMailProviders` carries that floor until the app starts syncing (GKM-010/011) and moves to macOS 15 / Xcode 26 itself; the ios-conventions rule (current minus one) already points there.

**Rejected:**

- **MailCore2** (C++/Objective-C, BSD-style): no release since 0.6.4 (2020) although the repository has new commits; a large C/C++ parsing surface for hostile mail (libetpan, ctemplate, tidy, ICU), callback/thread model with no Swift concurrency, a heavy build on iOS.
- **Postal** (Swift over libetpan, MIT): unmaintained since 2019.
- **Kitura/Swift-SMTP** (Apache-2.0): Kitura is no longer actively developed (last change April 2025); pre-NIO socket code and no uncertain-send state.
- **sersoft-gmbh/swift-smtp** (Apache-2.0, maintained, NIO-based): needs swift-tools 6.4 (newer than the Swift 6.2 we build with), and it reports success or an error without saying where the transaction stopped, which the outbox needs to tell `notSent` from `uncertain`.
- **Swift MIME parsers on GitHub** (miximka/MimeParser, bengottlieb/marcel and others): unmaintained, read-only, no RFC 2231 or limits.
- **swift-nio-imap's `IMAPCommands`**: see above; a candidate to adopt once it supports custom trust and timeouts.

**Verified** against a real local server (GreenMail 2.1.3, `swift/GitKittieMailProviders/scripts/test-mail-server.sh`): TLS with a pinned test CA, folders, incremental fetch by UID, flags, MOVE with UIDPLUS ids, attachments byte for byte, send then Sent reconciliation, uncertain sends (lost reply over TLS and a real TCP cut), STARTTLS through a TLS front, STARTTLS downgrade refused, UIDVALIDITY reset with stale UIDs refused, reconnect after a network cut, IDLE, malformed mail, and no password in any log. Not yet run against iCloud: that needs Sil's test account (GKM-004; how to run it is in the package README).

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

Open technical questions: validate provider OAuth scope/approval and quotas; prototype encrypted CloudKit metadata, identity mapping and archive key recovery; determine local history/attachment storage budgets and iOS file access; measure multilingual classifier accuracy and set release thresholds; choose shared package names after repo audit; validate pricing and relay demand; complete threat model, privacy, accessibility and App Store review before launch.
