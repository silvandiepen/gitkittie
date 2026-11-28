---
id: MAIL-043
title: "Space rules are materialised"
date: 2026-11-24
status: proposed
---

# MAIL-043: Space rules are materialised

**Decision.** Space rules are materialised: saving rules adds what they match now (after a live preview), and every sync, import or open adds new matches. A message taken out by hand goes to `excluded` and no rule adds it back; adding it by hand clears that. Deleting a rule keeps what it added. Rules are AND of sender address, sender domain (with subdomains), List-Id, subject words and account; a rule needs at least one message condition

**Why.** Membership the person can see and correct; rules never fight a manual choice (Architecture.md, manual overrides automation). An account alone would copy the account view. GKM-022

**Links.** GKM-022
