---
id: MAIL-057
title: "Unsubscribe requests are tracked in `metadata/unsubscribes.json` (user data, records..."
date: 2026-11-24
status: proposed
---

# MAIL-057: Unsubscribe requests are tracked in `metadata/unsubscribes.json` (user data, records...

**Decision.** Unsubscribe requests are tracked in `metadata/unsubscribes.json` (user data, records with id, account, list, method, target, dates): requested when approved or queued, pending when the list answered 2xx or the message was sent, failed on a refusal, a redirect, a network error, an outbox failure, or mail dated more than two days after the request; confirmed after two weeks without mail from the list, or when you say so. "Request sent" is never shown as "unsubscribed"

**Why.** A list accepting a request proves nothing; its mail stopping does. Two days is what large providers ask lists to honour. GKM-020

**Links.** GKM-020
