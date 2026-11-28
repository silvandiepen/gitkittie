---
id: MAIL-074
title: "\"Your name\""
date: 2026-11-25
status: accepted
---

# MAIL-074: "Your name"

**Decision.** "Your name": the name on mail you send is asked when an account is added (Mac and iPhone), kept in its `account.json` (`MailAccount.senderName`) and changed in the account's settings (Mac: Account Settings… in the sidebar's menu; iPhone: Settings ▸ the account). Sent mail carries it in From (`MailAccount.sendingAddress`, the identity `SendingAccountSettings` registers); empty sends the address alone. The account's sidebar name is never put on sent mail

**Why.** Decided by Sil (GKM-011). An iCloud account used to send as "iCloud", its label. `SendingTests.testYourNameIsOnMailYouSendNotTheAccountsName` checks the From header the composer writes; `AccountTests` checks setup and the registered identity against the test server. GKM-042

**Links.** GKM-011, GKM-042
