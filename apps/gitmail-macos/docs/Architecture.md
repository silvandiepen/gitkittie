# Architecture

## Boundaries and providers

SwiftUI macOS first; iOS/iPadOS later. UI-independent core in a shared Swift package under swift/ (name after existing package audit). AppModel is UI-facing state. Separate provider adapter, MIME parser, store, classifier, index, sync coordinator and outbox. No cross-app imports. Reuse existing services only where appropriate.

Provider adapters expose capabilities and normalized operations: enumerate folders/labels, incremental fetch, MIME/attachments, flags, move/archive/trash, drafts, send and reconciliation. Generic IMAP/SMTP with TLS first, iCloud app-specific password; Gmail OAuth/API or approved IMAP; Outlook/Microsoft 365 OAuth/Graph or supported IMAP/SMTP. Yahoo, Fastmail and custom domains via supported protocols. Proton Bridge desktop candidate only, not mobile promise. Verify scopes, approval, quotas and enterprise policies. Credentials in Keychain, never files or Git; avoid primary passwords when supported alternatives exist.

## Storage and identity

Provider is authoritative for live mail and flags. Explicitly preserved archive files are independently owned. GitKittie metadata has separate sync; SQLite FTS5 is a rebuildable index. Suggested schema, in two places.

The mail folder holds only what the user owns and may sync, back up or put under version control:

    Mail/accounts/<account-id>/messages/<year>/<month>/<local-id>.eml
    Mail/accounts/<account-id>/messages/<year>/<month>/<local-id>.md
    Mail/blobs/<content-hash>
    Mail/archive/
    Mail/spaces/
    Mail/drafts/
    Mail/views/

Device-local state lives outside it, in the app's Application Support container, and is never synced:

    <Application Support>/Mail/index.sqlite
    <Application Support>/Mail/state/<account-id>/   (sync cursors, UIDVALIDITY, IDLE state)
    <Application Support>/Mail/cache/                (downloaded bodies and attachments not pinned)
    <Application Support>/Mail/metadata/classification.json   (your corrections and rules, GKM-017; to CloudKit with GKM-026)
    <Application Support>/Mail/preferences/          (remote images, notifications)

Each device has its own position at each provider, so sync cursors are per device; in a shared folder two devices would overwrite each other's. The index is rebuilt from the folder, so losing it costs time, not data. Keeping both out of the folder means pointing GitKittie Folder, iCloud Drive or Git at `Mail/` can never commit an index on every change or mix two devices' cursors.

Preserve original RFC 5322/MIME in EML; derive readable Markdown with YAML (id, messageId, references, sender, recipients, subject, date, attachment refs). Separate mutable metadata. Markdown is not lossless HTML/MIME; retain original signatures, inline images and attachments. Atomic writes, schema migrations, safe paths and integrity hashes. Deduplicate attachment blobs within appropriate access boundaries. Attachments on demand, pin for offline. Index, cache and sync state are outside the mail folder (above), so they cannot reach Git or folder sync. Encrypted message support is separate; preserve originals without modification.

Account-scoped local UUID, provider ID where available, IMAP mailbox + UIDVALIDITY + UID as remote mapping; Message-ID/content fingerprint are reconciliation signals, not globally unique. Handle moves, UID resets, missing/duplicate IDs, aliases and Gmail label duplication. Thread graph from References/In-Reply-To with conservative fallback, never subject alone. Each message remains independent. Reply preserves recipients, Reply-To, account identity and standard headers; never expose internal tags.

## Multi-device sync

Each device connects directly to provider. Provider syncs live messages, flags, folders/labels and Sent. Incremental cursors per account/folder, checkpoint after durable writes, reconcile missed changes and UID resets. IMAP IDLE on active desktop with reconnect/backoff and polling fallback; respect throttling, network and token expiry.

Private CloudKit proposed for spaces, tags, memberships, rules, corrections, notes, preferences and pins. Explicit cross-device account mapping, not display address alone. Credentials device-local by default; authorize accounts on new devices. Explain opt-out, unavailable iCloud/quota, metadata privacy and export. Private database is not a blanket end-to-end encryption guarantee; design encrypted sensitive records and key recovery. No raw messages/attachments in metadata sync by default.

Idempotent durable operations, record revisions, change tokens and tombstones. Merge independent memberships; deterministic scalar conflicts; preserve conflicting notes/drafts. Manual classification overrides automation. Persist offline action journal and visible retry state. Reconcile provider changes before destructive operations; never resurrect deleted messages from stale cache. Avoid syncing whole SQLite database or mailbox Git repository.

**What exists for everyday actions (GKM-015).** Read, flag, move, archive, trash and delete-from-Trash apply in the store at once (`MailStore+Actions.swift`) as rows of the account's action journal in `state/<account-id>/sync.sqlite` (MAIL-034). The index shows the provider's state with the open rows laid over it, so a sync pass, an index rebuild or a UIDVALIDITY reset never undoes a change that has not reached the provider. `ActionReplayer` (MailSync) sends the journal over its own connection, kicked by every action and by every sync pass, backing off while offline; rows that cancel out (Undo before reconnecting) send nothing, flags go as one STORE per folder and value, moves as one MOVE per folder pair. Conflicts follow MAIL-035 (the provider wins; a message that left its folder is never brought back); archive and trash folders follow MAIL-036; Undo, and the CONDSTORE flag sync, MAIL-037. Verified against the real local server (`MailActionsIntegrationTests`): offline actions show at once, survive a sync, and reach the server once on reconnect; a replay stopped after the server acted does not act twice; COPY + UID EXPUNGE without MOVE; Undo before and after the server has it; delete permanently keeps the local file and Undo restores exactly one copy; a flag changed elsewhere is not overwritten; a message moved or deleted elsewhere is not brought back.

Archive is third layer: preserved messages survive provider deletion. Local-only archives do not automatically appear elsewhere. Portable encrypted export first, encrypted archive sync or user-selected shared storage later, with integrity, key recovery, quota, deletion and restore tests. Distinguish provider deletion, archive deletion and cache eviction. Account disconnect offers keep/export or remove local files with consequences.

## Sending and drafts

Durable outbox, operation ID, stable outgoing Message-ID, recipient/account snapshot and queued/sending/sent/failed/uncertain states. SMTP acceptance is not delivery confirmation. If possible acceptance followed by disconnect, reconcile Sent/provider history before retry; no blind resend. Provider-specific Sent copy behavior avoids duplicates. Draft versions and conflict copies; shared draft send needs single owner where supported, never auto-submit from multiple devices. Test Bcc, reply-all, attachments, cancellations and retries.

**What exists (GKM-013, GKM-014).**

*Drafts and composing* (`MailCompose` in GitKittieMailKit). A draft is JSON in `Mail/drafts/<draft-id>/draft.json`, with its last 20 revisions in `versions/` and its attachments by SHA-256 in `attachments/`. Every save names the revision it started from; a save from a stale revision (another window, or another device through a synced folder) becomes a new draft marked as a conflict copy, and files a sync tool leaves beside `draft.json` are adopted the same way, so no edit silently wins. The compose window saves within two seconds of any edit and is restored with its draft after a relaunch. `ReplyBuilder` makes Reply (Reply-To, else From; your own message goes back to its recipients), Reply All (To and Cc, each address once, none of your own) and Forward (no recipients, no In-Reply-To, the original's attachments), answering from the address the message reached, with In-Reply-To and References (trimmed to the root and the newest 19). `MessageComposer` sends the Markdown as text/plain and HTML generated from it by `MarkdownHTML`, which escapes everything typed (raw HTML in the text or in a quote is shown, never sent as markup) and keeps only http, https and mailto links. Bcc is envelope only.

*The outbox* (`MailOutbox` in GitKittieMailProviders). Each send is `<Application Support>/Mail/state/outbox/<operation-id>/` with `message.eml` (the exact bytes, written first) and `entry.json` (state, attempts, the envelope and recipient snapshot, the draft for Cancel). `sending` is on disk before the connection opens. Only `notSent` (the server certainly lacks the message) is retried automatically, with the same bytes and backoff, five times, then `failed`. `uncertain` (the end of the message went out and no answer came back, or the app stopped mid-send) is looked for by Message-ID in Sent, All Mail and, when the message went to the account itself, the inbox; found means sent, not found leaves it uncertain and visible, and Send Again looks once more before queuing it. The Sent copy follows the account's `SentCopyPolicy`: `providerFiles` (Gmail) never appends, `append` (generic IMAP) appends after a search finds none, `detect` (iCloud until GKM-004 confirms) waits two minutes for the provider's copy first. An exclusive lock lets one process own the outbox. Accounts reach it through `SendingAccount` (identity, SMTP and IMAP endpoints, a Keychain `CredentialReference`, the Sent policy), which account setup (GKM-010) registers.

*Verified* against the real local server with real TCP cuts (`swift/GitKittieMailProviders`, `OutboxIntegrationTests`): a cut before the greeting, at EHLO, AUTH, MAIL FROM, RCPT TO, DATA, in the body, at the end-of-data marker, after acceptance and at QUIT each end with exactly one copy at every recipient and in Sent; the outbox stopped after marking `sending`, after the SMTP outcome, after marking `sent` and after the Sent append each resume without a second copy; no Bcc in any stored or delivered header.

## Spaces and export

**What exists (GKM-022, GKM-023).**

*Spaces* (`MailStore+Spaces.swift`, MAIL-042, MAIL-043). One file per space in `Mail/spaces/<space-id>.json`, pretty-printed JSON with sorted keys, dates ISO 8601 in whole seconds. This is the stable format GKM-026 maps to CloudKit records:

    {
      "format": 1,                          // a file with a higher number is shown, never rewritten
      "id": "<uuid>", "name": "Garden", "icon": "leaf.fill", "color": "green", "order": 0,
      "created": "…Z", "modified": "…Z",
      "rules": [{ "id": "<uuid>", "sender": "…", "domain": "…", "list": "…", "subjectWords": "…", "account": "<account-id>" }],
      "members":  [{ "message": "<local-id>", "account": "<account-id>", "messageId": "…", "emlSha256": "…", "added": "…Z", "source": "manual" | "rule:<rule-id>" }],
      "excluded": [ same shape: taken out by hand, never re-added by a rule ]
    }

Rule fields that are absent are not checked; `color` is one of the Tasks board names. `members` and `excluded` merge as sets keyed by `message` (independent memberships, Multi-device sync above); scalar fields take the newer `modified`. The index holds a copy in `space_members`, refilled from the folder on open and after a rebuild, so a space filters the list, search, unread counts and the attachment library in SQL. A file that cannot be read is listed in the sidebar's notice and left alone. Nothing in spaces reaches a provider: deleting a space removes its file only.

*Attachment library* (`AttachmentLibrary.swift`, MAIL-045): every non-inline attachment across accounts from `message_blobs` (index schema 3), filtered by kind (media type or extension), file name, sender, date, account, space and size.

*Export* (`MailStore+Export.swift`, MAIL-044): a message, conversations, a space or an account into a new folder the person picks, in the mail-folder layout, originals byte for byte. Tested by export → import into a fresh store → byte comparison, and by opening the export as a mail folder.

## Background processing

macOS can monitor while running. iOS background execution is opportunistic, not guaranteed instant notifications or continuous filtering. Core mail requires no custom server. Optional self-hosted relay later for continuous monitoring and push, with explicit trust boundary, secure credentials and minimal notification payload. Do not advertise guaranteed instant push until validated.

## iOS and iPadOS

The iPhone and iPad app (GKM-027) uses the same two packages as the Mac (MAIL-050): GitKittieMailKit (iOS 17) and GitKittieMailProviders (iOS 18, for swift-nio-imap). Both build and pass their tests on the iOS Simulator, including the integration tests against the local GreenMail server (the simulator shares the Mac's loopback; the tests find the server's state through `SIMULATOR_HOST_HOME`). CI runs them on an iPhone simulator (`.github/workflows/swift-mail-ios.yml`). What differs, and where:

| Area | macOS | iOS |
| --- | --- | --- |
| Attachment text | `IsolatedTextExtractor` → `GitMailExtractor.xpc` (MAIL-031) | `InProcessTextExtractor`, strict limits and a crash record (MAIL-052) |
| Reader web view | Context menu trimmed to reading actions; magnification | No long-press menu or link preview; no data detectors |
| Keychain | Data protection keychain; tests use the login keychain | Data protection keychain only; the test needs an entitled host (GKM-027) |
| Mail folder | `Documents/Mail` in the container, or a folder the person picks (security-scoped bookmark) | `Documents/Mail` in the container only (MAIL-051) |
| Sync | IDLE while the app runs | IDLE only while active; background tasks otherwise (MAIL-053) |

Everything else — MIME, the store and its atomic writes, the index, threads, classification, compose, the outbox, IMAP/SMTP over swift-nio and swift-nio-ssl (system trust through SecTrust on both) — is the same code. Both platforms flush with `fsync` (not `F_FULLFSYNC`), unchanged: a power loss can lose the last writes but never tears a file (writes are renamed into place), and the provider still has the mail.

*Files* (MAIL-051). The mail folder is `<container>/Documents/Mail` and appears in the Files app under On My iPhone ▸ GitKittie Mail ▸ Mail, so the person can open, copy or share their `.eml` and `.md` files. Device state stays in `Library/Application Support/Mail` (not visible). Files can change the mail folder while the app is suspended; the index is rebuildable from the folder (MAIL-005), so the app checks it against the folder when it becomes active (GKM-027). iCloud Drive is not a supported mail-folder location on iOS for now: it evicts files to placeholders and keeps conflicting copies, which the store's hashes would read as corruption; devices share mail through the providers (MAIL-001) and metadata through CloudKit (GKM-026). When a picked folder is added later, iOS bookmarks are made without `.withSecurityScope` (a macOS-only option), and every access needs `startAccessingSecurityScopedResource` and an `NSFileCoordinator`, since Files and other apps write there too. File protection is `CompleteUntilFirstUserAuthentication`, the same class as the Keychain items (`AfterFirstUnlockThisDeviceOnly`), because background sync writes while the phone is locked.

*Background* (MAIL-053). iOS suspends the app soon after it leaves the screen and closes its sockets, so there is no IMAP IDLE in the background. While active, the app syncs and holds IDLE as on the Mac; on entering the background it stops the sync loop and IDLE, and finishes an in-flight sync step or SMTP submission under `beginBackgroundTask` (the outbox journal and Sent reconciliation keep a send that is cut off at most once). `BGAppRefreshTask` (a few seconds to about 30 s, when the system chooses) checks each account's INBOX for new UIDs, fetches those messages within a small byte budget and posts local notifications; `BGProcessingTask` (minutes, usually on power and idle) imports the backlog, rebuilds or catches up the index and extracts attachment text. Neither is guaranteed to run, so nothing promises instant notifications; that needs the optional relay. Connections to a server on the local network ask for Local Network permission (`NSLocalNetworkUsageDescription`); loopback does not.

*Storage budgets.* Phones have less space and pay for cellular data, so the iOS app sets limits the Mac does not need (defaults; the person can change them): the first sync imports the newest 30 days of each folder and older mail on request or by search on the server; attachments are fetched on demand, never automatically on cellular and only up to 5 MB on Wi-Fi; attachment text is extracted only within MAIL-052's limits; the device folder's `cache/` is capped at 500 MB, evicted least recently used, and excluded from backup. Import pauses, with a message, when free space drops under 1 GB. The original `.eml` of a message that was imported is never evicted: it is the person's mail (MAIL-003).

*Attachment text* (MAIL-052). iOS has no XPC services for apps, so the extractor runs in the app's process with `Limits.inProcess`, one parse at a time at utility priority, a 10 s timeout for the caller and a crash record (`<Application Support>/Mail/cache/attachment-text-attempts/<sha256>.inflight`): if the app dies while parsing, those bytes are never parsed again. It runs only while the app is active or in a `BGProcessingTask`.

## Security and privacy

TLS validation; no secret logging. OS data protection, optional encrypted archive, restricted file access. Sandbox HTML, disable scripts and remote loads by default; no tracking pixel fetch. Warn on suspicious URLs/impersonation; trust authentication evidence only from known boundaries. Validate attachment size/type, isolate extraction, guard against malformed MIME, decompression bombs and path traversal. Email and attachments are untrusted input, never agent instructions; local AI optional, no automatic external transfer. Explicit scoped read-only agent access by default. Redacted diagnostics. Git opt-in warns about confidentiality and persistent history; prefer metadata only. All Git host access via GitPont.

## Implementation references

Apple iCloud: https://support.apple.com/en-us/102525

Gmail API: https://developers.google.com/workspace/gmail/api

Graph mail: https://learn.microsoft.com/en-us/graph/api/resources/mail-api-overview

CloudKit: https://developer.apple.com/documentation/cloudkit/cksyncengine

IMAP RFC 9051; SMTP RFC 5321; message format RFC 5322; MIME RFC 2045–2049. Validate current provider requirements before implementation.
