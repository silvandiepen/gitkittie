---
id: MAIL-045
title: "The attachment library reads the index only (schema 3 adds name, size, inline and..."
date: 2026-11-24
status: proposed
---

# MAIL-045: The attachment library reads the index only (schema 3 adds name, size, inline and...

**Decision.** The attachment library reads the index only (schema 3 adds name, size, inline and Content-ID per blob); inline parts are hidden unless asked for. Bytes are read only on request: Quick Look of the reader's quarantined private copy, or Save As, which writes the hash-checked bytes and sets the quarantine attribute

**Why.** Listing never touches attacker bytes (ThreatModel §4); one preview path for reader and library. GKM-023

**Links.** GKM-023
