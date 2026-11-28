---
id: MAIL-033
title: "\"Load remote images\" is per message or per sender address, kept on this device..."
date: 2026-11-24
status: proposed
---

# MAIL-033: "Load remote images" is per message or per sender address, kept on this device...

**Decision.** "Load remote images" is per message or per sender address, kept on this device (`preferences/remote-images.json`), ignored for any message with a sender warning; tracking pixels and CSS references are never loaded either way

**Why.** The address is spoofable, so a lookalike sender cannot borrow a real sender's allowance. Moves to encrypted CloudKit metadata with GKM-026. GKM-012

**Links.** GKM-026, GKM-012
