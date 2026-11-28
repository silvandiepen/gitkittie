---
id: MAIL-096
title: "**Account editing**"
date: 2026-11-26
status: proposed
---

# MAIL-096: **Account editing**

**Decision.** **Account editing**: the account's name (the sidebar's), "Your name" (MAIL-074), "Remove mail deleted elsewhere", a new password and the servers. A password is checked against both servers before it replaces the Keychain item; changed servers (host, port, user name, the outgoing server's TLS or STARTTLS) are checked with the new password, or the one in the Keychain when none is typed, and nothing is saved when a check fails; then the account's sync starts again and sending takes the new servers. iCloud's servers are Apple's and are shown, not edited

**Why.** Same rule as setup (GKM-010): never save settings that were not verified, never put a password anywhere but the Keychain. `MailboxSettingsAppTests.testServersAndPasswordAreCheckedBeforeTheyAreSaved` against the test server. GKM-066

**Links.** MAIL-074, GKM-010, GKM-066
