---
id: MAIL-039
title: "Your corrections and rules are user data in `<Application..."
date: 2026-11-24
status: proposed
---

# MAIL-039: Your corrections and rules are user data in `<Application...

**Decision.** Your corrections and rules are user data in `<Application Support>/Mail/metadata/classification.json`: records with a stable id, account and dates, ready for private CloudKit (GKM-026). A correction finds its message by content fingerprint; one that only sets the purpose also follows the Message-ID, one that lowers risk ("Not phishing") never does. A rule is only made when you choose it after a correction, scoped to one account and one sender address or List-ID; rules set purpose and never lower risk. A correction beats a rule, a rule beats the classifier; both survive rebuilds and rule-set upgrades

**Why.** A reused Message-ID must not let a phish inherit your "Not phishing"; never generalising silently is Classification.md, step 6. GKM-017

**Links.** GKM-026, GKM-017
