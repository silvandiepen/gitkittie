---
id: MAIL-110
title: "A blocking rule **moves mail at the provider** through the action journal (MAIL-034)"
date: 2026-11-26
status: proposed
---

# MAIL-110: A blocking rule **moves mail at the provider** through the action journal (MAIL-034)

**Decision.** A blocking rule **moves mail at the provider** through the action journal (MAIL-034): applying it moves every message it decided out of every folder but All Mail, Trash and Junk into the account's Junk (`MessageAction.moveToJunk`; a `Junk` folder is created on first use without one, and counts as Junk at once, like Trash in MAIL-102) or Trash (as Move to Trash), as one journal batch replayed in batches (MAIL-101). Applying is **one Undo** for the rule and the moves; Redo makes both again. New mail is moved after each sync (`SendersModel.afterSync`, by arrival), with no Undo of its own, on every device that has the rule; mail that arrived before the rule, or that you moved out of Junk yourself, is moved again only when the rule itself is added, turned on or edited. **Flagged mail and mail in a space stay where they are**, decided when the mail is sorted (`SenderRuleProtection.flagged`, `.space`) and checked again when it is moved (`MailStore.messagesToBlock`); account security mail also stays (MAIL-054). Unlike other rules a block acts on risky and corrected mail: it is about who sent it, and Junk or Trash is the safer side. Until the move lands, the mail is muted (`SenderDisposition.muted`), so no index schema change

**Why.** Sil, GKM-067 review (block-protected: stays). A flag or a space is the strongest "keep this" the person has given (MAIL-059 uses the same two); re-checking at the move covers mail flagged or put in a space after it was sorted. Moving only on arrival and on a rule change means a rescued message is not dragged back on every sync. `BlockingRulesTests`, `BlockSenderAppTests`. GKM-072

**Links.** MAIL-034, MAIL-102, MAIL-101, MAIL-054, GKM-067, MAIL-059, GKM-072
