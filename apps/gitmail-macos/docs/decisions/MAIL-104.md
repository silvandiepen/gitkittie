---
id: MAIL-104
title: "A message without a Message-ID that left its last folder, while some folder still has..."
date: 2026-11-26
status: proposed
---

# MAIL-104: A message without a Message-ID that left its last folder, while some folder still has...

**Decision.** A message without a Message-ID that left its last folder, while some folder still has mail not downloaded here, is looked for in those folders by what a move keeps (`DeletionProbe` in MailSync): `UID SEARCH` by its sender (`FROM`, or the From header's text) and the day it was received (`SINCE`/`BEFORE`, INTERNALDATE, which COPY and MOVE keep), and again by the day it is dated (`SENTSINCE`/`SENTBEFORE`, its Date header), each a day either side (servers compare days in their own zone). A hit is taken for the message when its RFC822.SIZE is the stored size, or when its `BODY[HEADER]` has every header field of the stored copy (names in any case, values unfolded, white space collapsed). The deletion is confirmed only when every search answered and no hit can be the message. When the check cannot tell (a hit gone between search and fetch, more than 20 hits to compare by header, a folder gone or reset under the search) nothing is marked and it is asked again later (MAIL-105). A hit that matches drops the notice, as a Message-ID found does (MAIL-075). It shares the pass's limit of 50 checks (`deletionChecksPerPass`) with the Message-ID searches

**Why.** Sil's rule (MAIL-075): a move is never taken for a deletion. On iPhone the window (MAIL-072, MAIL-079) means almost every account has mail left at the provider, so without this a message with no Message-ID was never marked there. Every comparison leans towards "still there": servers do not return identical bytes (GreenMail drops the header's closing empty line and reports a moved message's size as its body's size, both seen in the tests), may add fields of their own, or refold lines, and a near-twin from the same sender on the same day with the same headers left unmarked costs nothing. `MailSyncIntegrationTests` against the test server with a 30-day window: deleted elsewhere is marked, moved into a folder whose mail the window leaves at the provider is not; `DeletionProbeTests` for the header comparison. GKM-043

**Links.** MAIL-105, MAIL-075, MAIL-072, MAIL-079, GKM-043
