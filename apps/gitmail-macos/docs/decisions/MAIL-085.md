---
id: MAIL-085
title: "Spaces have a notification choice of their own, beside the account and list ones..."
date: 2026-11-25
status: proposed
---

# MAIL-085: Spaces have a notification choice of their own, beside the account and list ones...

**Decision.** Spaces have a notification choice of their own, beside the account and list ones (MAIL-041): like the rest of Focused (default), Always (never from Quarantine) or Never, one per space across accounts, in `preferences/notifications.json` (`spaces`; a file without the key still reads). A new message's list and every space it is in each have a say: Never anywhere wins, then Always anywhere, else its home decides. An account set to Off, Quarantine, read mail, history and a sender rule that mutes or silently archives are never overruled. Space rules run over new mail before notifications are considered, and the store hands each arrival its spaces through the membership index. A deleted space's choice is left in the file

**Why.** A space is a project or a person, which is what people want to hear about or not (Classification.md, Notifications). Never winning is the safe reading of a conflict: someone who silenced a space expects silence, and a missed notification still leaves the mail in its views. Dropping a choice when its space file is briefly unreadable (another device writing it) would lose it. GKM-037

**Links.** MAIL-041, GKM-037
