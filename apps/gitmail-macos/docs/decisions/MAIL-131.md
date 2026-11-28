---
id: MAIL-131
title: "**A message has a stable link**"
date: 2026-11-27
status: proposed
---

# MAIL-131: **A message has a stable link**

**Decision.** **A message has a stable link**: `gitkittie-mail://message/<account-id>/m-<SHA-256 of its Message-ID, hex>`, or `f-<content fingerprint>` for a message without a Message-ID (`MessageLink` in MailStore). It is resolved in the link's account first, then in every account; when several stored messages match, the oldest (then the lowest local id) wins. Mail on the Mac and on iPhone and iPad opens it (`CFBundleURLTypes`; on the Mac through `MailAppDelegate.application(_:open:)`, on iOS `onOpenURL`) as a notification opens a message (MAIL-086), also when the link launched the app. Message ▸ Copy Link to Message and the row menus copy it. Resolving hashes the Message-IDs of the account (an indexed read, no schema change); a link to mail that is not on this device says so and opens nothing else

**Why.** The local id is made per device and again when mail is downloaded afresh, so a link built on it would break on a resync, a rebuilt mail folder or another device; Message-ID and the fingerprint come from the message itself (Architecture.md, Storage and identity: signals, not identity, which is why a link only ever *opens* a message, never merges or acts on one). The link goes into Tasks cards, which live in a Git repository, so it says nothing about the message: the Message-ID is hashed (it often carries the sender's host name and a time). Looking in every account covers an account removed and added again, and another device until GKM-026 maps accounts. `MessageLinkTests` (rebuild, fresh download with new local ids, account gone, own account first, malformed links), `MessageLinkAppTests`. GKM-033

**Links.** MAIL-086, GKM-026, GKM-033
