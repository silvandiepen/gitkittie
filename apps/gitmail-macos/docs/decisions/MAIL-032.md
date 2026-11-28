---
id: MAIL-032
title: "HTML mail is shown through four independent layers"
date: 2026-11-24
status: proposed
---

# MAIL-032: HTML mail is shown through four independent layers

**Decision.** HTML mail is shown through four independent layers: an allowlist sanitizer (MailHTML), JavaScript off with no script bridge, a content rule list plus `default-src 'none'` CSP, and a navigation guard that lets only the message document load. Links point at `x-gkm-link:<n>`; the real destination is shown before anything opens

**Why.** Each layer alone stops remote loads in tests; no single bug reaches the network. GKM-012

**Links.** GKM-012
