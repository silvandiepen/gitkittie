---
id: MAIL-055
title: "A rule's identity is account + List-ID + the organisation (Public Suffix List) that..."
date: 2026-11-24
status: proposed
---

# MAIL-055: A rule's identity is account + List-ID + the organisation (Public Suffix List) that...

**Decision.** A rule's identity is account + List-ID + the organisation (Public Suffix List) that sent the list when the rule was made, or account + From address; a copied List-ID from another domain is not matched. Rules are one ordered list: the first enabled rule that matches and does not exclude the message wins; the reader names the winner, its position and every later rule that also matched. Every change (add, edit, turn off, reorder, remove) is shown first as a dry run over every message the changed rules could touch (`previewSenderRules`, writes nothing), with the messages each rule leaves alone and why; unticking a message stores its content fingerprint as an exclusion. Applying saves exactly the previewed list; Undo restores the previous list. Company grouping in the Senders view is informational. Open history is counted only for messages opened in this app on this Mac (`preferences/open-history.json`, device-only) and says so

**Why.** Authentication is still "no evidence" in the app (MAIL-038), so a list rule cannot rest on a verified sender; tying it to the sending organisation is the strongest identity available until GKM-004/GKM-029 verify `authserv-id`s. GKM-019

**Links.** MAIL-038, GKM-004, GKM-029, GKM-019
