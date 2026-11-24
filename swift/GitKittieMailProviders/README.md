# GitKittieMailProviders

How GitKittie Mail talks to mail providers. Library choice and reasons: MAIL-017 in
`apps/gitmail-macos/docs/Decisions.md` (GKM-002). Models and MIME (`MailCore`, `MailMIME`) come
from `../GitKittieMailKit`.

| Target | What it is |
|---|---|
| `MailProvider` | Protocol-agnostic interfaces: `MailboxConnector` / `MailboxSession` (folders, incremental fetch by cursor, raw messages, flags, move, append, Message-ID search, IDLE), `MailSubmitter` with `SubmissionOutcome` (`accepted` / `notSent` / `uncertain`), `SubmissionFollowUp`, `SendReconciler`, `ReconnectPolicy`, `Secret` and `MailLog` (redaction) |
| `MailNet` | Shared transport: swift-nio-ssl TLS (system trust, or explicit custom roots), connect timeouts, loopback-only plaintext |
| `MailIMAP` | `IMAPConnector` / `IMAPSession` on Apple's swift-nio-imap codec. Implicit TLS only (993) |
| `MailSMTP` | `SMTPSubmitter`: implicit TLS (465) or STARTTLS (587), AUTH PLAIN / LOGIN / XOAUTH2 |
| `MailOutbox` | The durable outbox (GKM-014): a journal in device state, at-most-once sending, reconciliation of uncertain sends by Message-ID, Sent copies by provider policy, `SendingAccount` for account setup to implement |
| `MailAccounts` | Account setup (GKM-010): provider presets (iCloud, Gmail, Fastmail, Yahoo), `AccountVerifier` (signs in to IMAP and SMTP without sending; `AccountSetupError` tells a wrong password, an unreachable server and an untrusted certificate apart), `KeychainCredentialStore`, `AccountConnections` |
| `MailSync` | `SyncCoordinator` (GKM-011): recent mail first, then history within a storage budget, cursors checkpointed after durable writes, byte-exact re-mapping after UIDVALIDITY resets and moves, flags and removals from the provider, IDLE (polling without it) with reconnect backoff. `SyncPlanner` holds its decisions as plain functions |
| `MailSpikeKit`, `gkmail-spike` | The GKM-004 end-to-end scenario and its command |

Needs Swift 6.2 (Xcode 26) and macOS 15 / iOS 18, because swift-nio-imap 0.5 does.

## Tests

```sh
swift test                              # unit tests; integration tests skip without the server
scripts/test-mail-server.sh start       # real IMAP/SMTP server on 127.0.0.1 (GreenMail, Java 11+)
swift test                              # now the integration tests run too
scripts/test-mail-server.sh stop        # or `clean` to also delete the jar and the test CA
```

The server script downloads GreenMail 2.1.3 once (checksum-pinned) into
`~/Library/Caches/GitKittieMail/test-mail-server`, makes a throwaway CA and a `localhost`
certificate there, and listens on loopback only: IMAPS 3993, SMTPS 3465, IMAP 3143, SMTP 3025,
admin API 3080. Nothing is added to the system keychain; tests trust that CA explicitly and still
check host names. Each integration test creates its own synthetic `@example.com` account and
asserts that its password never appears in the captured log.

Network faults are real, not simulated: `FaultProxy` (Tests/MailIntegrationTests/Support) cuts TCP
connections in front of the server (all of them on demand, before the greeting, when the client sends a
given command or body text, or right after the server accepted a message), and `StartTLSFront` adds the STARTTLS step GreenMail lacks
(iCloud's port 587 requires it) before relaying to GreenMail. CI starts the server and sets
`GKM_REQUIRE_TEST_MAIL_SERVER=1`, so there a missing server fails instead of skipping.

Known GreenMail 2.1.3 behaviour the tests account for: RFC822.SIZE reports the body's size, not
the whole message's (so storage-budget tests use exact byte counts); delivery adds `Return-Path`/`Received`
and drops the line break before the end-of-data dot; and LOGOUT does not deselect, so deleting a
mailbox that an earlier session had selected kills the deleting connection (a server bug,
reproducible with `openssl s_client`; real servers do not do this).

## The GKM-004 spike

`gkmail-spike` runs one scripted pass over a real account: TLS and folders, an incremental-fetch
baseline, send to itself with an attachment, Sent reconciliation (appends a Sent copy only if the
provider does not keep one), incremental fetch with the attachment checked byte for byte, flags,
a move, an uncertain send (the connection is dropped after the server's reply arrives, unread),
a UIDVALIDITY reset (deletes and recreates its own folder), IDLE, a reconnect, a malformed
message, and clean-up. It only touches its own messages and a folder named
`GitKittieMail-Spike-…`, which it deletes. Afterwards it searches its own log file for the
password and fails if it finds it.

Against the local server:

```sh
scripts/test-mail-server.sh start
swift run gkmail-spike --local
```

Against iCloud (needs an iCloud test account with an app-specific password from
appleid.apple.com → Sign-In and Security → App-Specific Passwords). The password is read from your
login Keychain only, never from a file, an argument or an environment variable:

```sh
# Store it once; -w with no value makes `security` prompt, so it never reaches shell history.
security add-generic-password -s gitkittie-mail-spike -a you@icloud.com -w

swift run gkmail-spike --icloud you@icloud.com --log-file /tmp/gkmail-spike.log
grep -c "your-app-password" /tmp/gkmail-spike.log   # must print 0 (the spike checks this too)

# Remove it afterwards:
security delete-generic-password -s gitkittie-mail-spike -a you@icloud.com
```

macOS asks once whether `gkmail-spike` may read the Keychain item. iCloud settings
(https://support.apple.com/en-us/102525): IMAP `imap.mail.me.com:993` TLS, SMTP
`smtp.mail.me.com:587` STARTTLS, user name = the full address. Other providers:
`--account you@example.com --imap host:993 --smtp host:465` (587 means STARTTLS).

Things to note on the iCloud run (record them on GKM-004): whether iCloud keeps its own Sent copy
for SMTP submissions (the spike reports it), how long delivery to the inbox takes, whether
IDLE wakes promptly, and the UIDVALIDITY step's behaviour on a deleted and recreated folder.
