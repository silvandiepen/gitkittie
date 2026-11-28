---
id: MAIL-097
title: "**Mail ▸ Settings… (⌘,)** on the Mac is a standard Settings window with General (sync..."
date: 2026-11-26
status: proposed
---

# MAIL-097: **Mail ▸ Settings… (⌘,)** on the Mac is a standard Settings window with General (sync...

**Decision.** **Mail ▸ Settings… (⌘,)** on the Mac is a standard Settings window with General (sync now, the search index, import), Accounts (the accounts, added, removed and dragged into order; per account its information and password, mailboxes, and servers), Notifications (MAIL-041, MAIL-085) and Storage (how far back, which attachments wait at the provider and how much the cache keeps, Free Up Space, the mail folder's place, size and the free space on its disk). It replaces the Offline Storage window, the Notifications sheet and the Account Settings sheet; the sidebar's Notifications… and Settings…, an account's Account Settings… and Mailboxes…, and View ▸ Offline Storage… open the matching tab. The attachment threshold and the cache size were hidden defaults and are now choices. The order of the accounts is kept on the device (`preferences/accounts.json`). iPhone and iPad get the same account and mailbox options under Settings ▸ the account (account name, Mailboxes, Servers) and reorder accounts with Edit. Not built: which view the window opens on, a choice of when mail is marked read (MAIL-073 as decided), and pausing downloads on the Mac when the disk is nearly full (the iPhone has it); GKM-067. Sil decided them: MAIL-106..108

**Why.** Sil: "where are the settings of Mail, where I can configure mailboxes?" Settings were spread over sidebar buttons, a right-click menu and the View menu. Apple Mail's Accounts pane (list left, account right) is the pattern Mac users know. The three not built are new behaviour, not settings that existed, and the read choice changes a decision of Sil's, so they wait for him. GKM-066

**Links.** MAIL-041, MAIL-085, MAIL-073, GKM-067, MAIL-106, GKM-066
