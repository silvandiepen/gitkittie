---
id: MAIL-082
title: "A server search costs at most one more connection per account"
date: 2026-11-25
status: proposed
---

# MAIL-082: A server search costs at most one more connection per account

**Decision.** A server search costs at most one more connection per account: each account's `ServerSearcher` (MailSync) runs its searches and downloads one at a time, each in a session of its own, beside the sync's, the action replay's and on-demand attachments' own (MAIL-063); a burst of searches never adds more than that one (Gmail allows 15 per account). The app asks 0.6 s after typing stops (`MailBrowser.serverSearchDelay`); a newer query cancels the older one, which stops before its next folder, and the newer one waits for it to close its connection. An unchanged query is not sent again when the list reloads (the sync reloads it as mail arrives). Per folder only the newest matches by UID are summarised (`UID FETCH` of ENVELOPE, flags, size, date), at most 50 (`ServerSearcher.defaultLimit`); the list shows the newest 50 of all accounts and says how many match in all

**Why.** Typing a word letter by letter would otherwise be a search per letter, each a full-text search over every left-out folder at the provider. One connection per purpose is the pattern the sync already follows, and serialising makes a burst of searches cost one connection, not one per keystroke. GKM-041

**Links.** MAIL-063, GKM-041
