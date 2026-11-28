---
id: MAIL-098
title: "**See All Mail from…** (row menu on the Mac, long press on iPhone and iPad) shows All..."
date: 2026-11-26
status: proposed
---

# MAIL-098: **See All Mail from…** (row menu on the Mac, long press on iPhone and iPad) shows All...

**Decision.** **See All Mail from…** (row menu on the Mac, long press on iPhone and iPad) shows All Mail, across every account and folder, narrowed to exactly that From address: the From chip (`SearchFilters.sender`, `SearchQuery.sender`, `m.from_address = ? COLLATE NOCASE` on index schema 8's `messages_by_sender`). It never matches a recipient or a longer address that contains it; the Person chip and `from:` stay word matches over every participant, as before. Escape (Mac) or the chip goes back to the view it was opened from. Where mail is left at the provider (MAIL-081), the server is searched by IMAP `FROM` and each hit's address is compared exactly. While the list shows single messages (searching, and this view), an action acts on those messages; a conversation row is still the whole conversation

**Why.** Sil asked for it (GKM-071) to delete everything from one sender. Acting on whole conversations there would also delete your replies and other people's messages in them; an exact address keeps "from X" what it says. GKM-071

**Links.** MAIL-081, GKM-071
