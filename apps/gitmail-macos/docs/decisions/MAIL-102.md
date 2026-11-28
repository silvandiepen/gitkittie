---
id: MAIL-102
title: "Mail whose only folders are its account's Trash or Junk shows only in those folders"
date: 2026-11-26
status: proposed
---

# MAIL-102: Mail whose only folders are its account's Trash or Junk shows only in those folders

**Decision.** Mail whose only folders are its account's Trash or Junk shows only in those folders. Every other view leaves it out: All Mail, an account, Focused and the category views, spaces, senders, Clean Up, unread counts, the badge, notifications and search; a search or folder view inside Trash or Junk still finds it. Trash and Junk are the folders with the role `trash` or `junk` in the sync state (SPECIAL-USE, else the well-known names, MAIL-036; GKM-066's per-account choices once they set those roles), and without a `trash` folder the `Trash` folder an action creates on first use. The index keeps a copy per account (`trash_and_junk_mailboxes`, index schema 8, refilled from the sync state on open and on every folder list, `MailStore.refreshTrashAndJunk`) and a column on each message (`messages.trash_or_junk`) that SQLite triggers keep right on every change to a message's folders, the message row or an account's Trash and Junk. Views filter on that column (`m.trash_or_junk = 0`). Mail in no folder (On My Mac, deleted at the provider, MAIL-075) is not affected; a copy in Trash beside a real folder keeps it in the views

**Why.** Sil: "If I move messages in trash, they shouldn't keep showing in Subscriptions" (GKM-075). A filter in the index, not in Swift afterwards, keeps counts and paging exact; one column of the row the view already reads keeps every view's query plan unchanged (`TrashAndJunkTests` pins it; 50,000 messages: `GKM_BENCHMARK=1 swift test --filter TrashAndJunkTests`). Triggers cover every writer of folder membership (sync, actions and their overlay, Undo, rebuild, recovery, a folder rename) without each having to remember it. GKM-075

**Links.** MAIL-036, GKM-066, MAIL-075, GKM-075
