---
id: MAIL-081
title: "When the sync leaves mail at the provider by design (a history window, `historyDays`,..."
date: 2026-11-25
status: proposed
---

# MAIL-081: When the sync leaves mail at the provider by design (a history window, `historyDays`,...

**Decision.** When the sync leaves mail at the provider by design (a history window, `historyDays`, or a storage budget, `historyBudgetBytes`) and an account in scope has a folder whose history is not complete here, a search also asks the provider and shows what it finds under "On the server", newest first, below the local results. The provider half of a search is its words and quoted phrases (`SearchQuery.searchTerms`: each in the subject, the sender or the text, IMAP `OR SUBJECT … (OR FROM … TEXT …)`), its people (each in From, To or Cc, by the envelope key and by `HEADER`, since GreenMail 2.1.3 matches FROM only against the whole address), `after:`/`before:` and the date chip (`SINCE`/`BEFORE` by day, then the exact received date), unread and flagged, the account and the folder. Without a word or a person nothing is sent (a server search would list whole folders). A space, a category the person chose (chip or `category:`) or "has attachment" are only known here, so the list says the server can't be searched for them; the category view the search starts in is not a filter for it (mail that is not downloaded has no category). Only folders that are not `historyComplete` are searched, and messages stored here are left out (by UID). No limit (the Mac's default) or nothing left out: no server search and no connection. Offline (the sync waits to retry) says so and asks nothing; the next reload after the sync reconnects searches

**Why.** Architecture.md promised older mail by search on the server (Storage budgets); the window (MAIL-072) made the phone's local search incomplete by design. Words and people are what IMAP SEARCH is good at; the rest is local knowledge. Searching only incomplete folders keeps the cost to the folders that can have an answer. GKM-041

**Links.** MAIL-072, GKM-041
