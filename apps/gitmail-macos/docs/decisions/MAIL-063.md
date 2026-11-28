---
id: MAIL-063
title: "Opening a left-out attachment fetches that one section once (`OnDemandFetcher`, its..."
date: 2026-11-25
status: proposed
---

# MAIL-063: Opening a left-out attachment fetches that one section once (`OnDemandFetcher`, its...

**Decision.** Opening a left-out attachment fetches that one section once (`OnDemandFetcher`, its own connection, concurrent opens share the download), decodes it as MailMIME does and keeps it in the cache by SHA-256; when it is the message's last missing part the message is completed instead (about the same bytes). Offline says so (`Failure.offline`) and changes nothing. Forward and export complete a message first; Reply uses the skeleton (exact header and text). A partial copy matches another (a second folder, a UIDVALIDITY reset) when the header, size, structure and every fetched section are identical; it never matches a complete message by itself: the original is fetched and bytes compared. A complete original (fetched to complete it, or arriving from another folder) is accepted for a partial copy only when it begins with exactly the same header, has the same text, and contains every part the copy holds; sizes are not compared, since a server's RFC822.SIZE is not always the octet count it sends (GreenMail's is not)

**Why.** Fetch once, never fake: the reader shows what is downloaded. Identity rules stay byte-based where bytes exist (MAIL-046); for a copy that by definition lacks bytes, everything it has must agree. IMAP never changes a message under a UID. GKM-036

**Links.** MAIL-046, GKM-036
