---
id: MAIL-107
title: "**Mail opens where it was left**, on the Mac and on iPhone and iPad"
date: 2026-11-26
status: proposed
---

# MAIL-107: **Mail opens where it was left**, on the Mac and on iPhone and iPad

**Decision.** **Mail opens where it was left**, on the Mac and on iPhone and iPad: the sidebar's view (a category, All Mail, an account, a folder, a space, Drafts, the Outbox, Attachments, Senders, Clean Up) and the conversation open in it. The place is saved as it changes, on this device in `preferences/last-place.json` beside the account order (`LastPlace.swift`), so a quit, a crash or iOS ending the app keep it. On opening, a view that is gone (account removed, folder gone from the stored mail and the sync state, space deleted) falls back to Focused; a conversation opens again only when that view still holds it, selected in the list, whose pages load up to its row when it is below the first, as for a notification (GKM-085, GKM-112); on iPhone it is pushed as the reader. Reopening it marks it read as opening does (MAIL-108). A search or a sender view is not kept: the view comes back without it. A notification opened at launch wins (MAIL-086). This replaces "opens in Focused" (GKM-018, MAIL-070)

**Why.** Sil: "Wherever you were last" (GKM-067). Per device, because what is open on the Mac says nothing about the phone. Kept in the model (`AppModel.open`, `MailBrowser.reopen`), not in each app's views, so both apps get it and it is tested once. `LastPlaceTests`, `NotificationOpenUITests` (iPhone, below the first page). GKM-067, GKM-112

**Links.** GKM-085, GKM-112, MAIL-108, MAIL-086, GKM-018, MAIL-070, GKM-067
