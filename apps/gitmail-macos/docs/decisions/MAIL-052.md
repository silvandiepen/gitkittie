---
id: MAIL-052
title: "iOS extracts attachment text in process (`InProcessTextExtractor`), not in an extension"
date: 2026-11-24
status: proposed
---

# MAIL-052: iOS extracts attachment text in process (`InProcessTextExtractor`), not in an extension

**Decision.** iOS extracts attachment text in process (`InProcessTextExtractor`), not in an extension: `Limits.inProcess` (10 MB in, 100 pages, 200k characters, a 5 s page budget), one at a time at utility priority, a 10 s caller timeout, and a crash record per blob SHA-256 so bytes that were being parsed when the app died are never parsed again. Only while the app is active or in a `BGProcessingTask`. macOS keeps the XPC service (MAIL-031)

**Why.** iOS has no XPC services for apps, and no extension point runs arbitrary parsing on demand; an extension would have a lower memory limit and still run the same PDFKit. Strict limits, the timeout and the crash record bound what one hostile PDF can cost: one failed parse, never a crash loop. GKM-025

**Links.** MAIL-031, GKM-025
