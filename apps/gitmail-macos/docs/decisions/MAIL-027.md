---
id: MAIL-027
title: "Server settings (hosts, ports, security, user names) live in `account.json`"
date: 2026-11-24
status: proposed
---

# MAIL-027: Server settings (hosts, ports, security, user names) live in `account.json`

**Decision.** Server settings (hosts, ports, security, user names) live in `account.json`; the password lives only in the data-protection Keychain, `…AfterFirstUnlockThisDeviceOnly`, one item per account: service `app.hakobs.gitmail.account`, account = the account's local id. Account setup verifies IMAP and SMTP before anything is saved

**Why.** Another device can reuse the servers but signs in for itself; the outbox reads the same item (GKM-014). GKM-010

**Links.** GKM-014, GKM-010
