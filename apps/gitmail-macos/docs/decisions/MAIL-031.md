---
id: MAIL-031
title: "Attachment text for search is extracted in `GitMailExtractor.xpc`, a sandboxed XPC..."
date: 2026-11-24
status: proposed
---

# MAIL-031: Attachment text for search is extracted in `GitMailExtractor.xpc`, a sandboxed XPC...

**Decision.** Attachment text for search is extracted in `GitMailExtractor.xpc`, a sandboxed XPC service with no entitlements (no network, no files), bytes in and text out, a 20 s watchdog that ends the process, and size/page/output limits. Text is cached per blob in `<Application Support>/Mail/cache/attachment-text/` and tried once

**Why.** PDF parsing is attacker input to a large engine; a crash or hang costs a helper process, never the app (ThreatModel §4). GKM-016

**Links.** GKM-016
