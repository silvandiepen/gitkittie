---
id: MAIL-024
title: "The composer is a native text editor over Markdown"
date: 2026-11-24
status: proposed
---

# MAIL-024: The composer is a native text editor over Markdown

**Decision.** The composer is a native text editor over Markdown; the text/plain part is the Markdown as typed and the HTML part is generated with every typed character escaped. The web rich editor from Tasks is not used for mail

**Why.** Quoted replies carry attacker-written text; it must never run through a script-enabled web view. Plain Markdown reads well in any client. GKM-013

**Links.** GKM-013
