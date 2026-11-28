---
id: MAIL-089
title: "Contrast (GKM-061)"
date: 2026-11-26
status: proposed
---

# MAIL-089: Contrast (GKM-061)

**Decision.** Contrast (GKM-061): on iOS the app's tint is `Theme.accentText` (#75A5FF), the accent for text and symbols on the raised rows of dark forms and sheets; white text sits on `Theme.accentFill` (#2B68E0: prominent buttons, the Read swipe, Send's circle); the Flag swipe is a darker orange (#C2410C). Informative text is `.secondary`, never `.tertiary`. The Mac keeps `Theme.accent` until it is measured by hand (GKM-062)

**Why.** `Theme.accent` is 4.3:1 on #2C2C2E rows and white on it 3.2:1; `.tertiary` text is 2.4:1 on the navy; white on the system orange 2.1:1. One colour can't pass both as text on navy and under white text, so there are two. `performAccessibilityAudit` in `MailFlowUITests`

**Links.** GKM-061, GKM-062
