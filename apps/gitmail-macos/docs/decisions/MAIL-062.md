---
id: MAIL-062
title: "A message larger than the on-demand threshold (`SyncOptions.onDemandThreshold`,..."
date: 2026-11-25
status: proposed
---

# MAIL-062: A message larger than the on-demand threshold (`SyncOptions.onDemandThreshold`,...

**Decision.** A message larger than the on-demand threshold (`SyncOptions.onDemandThreshold`, default 1 MB of encoded size) is fetched part by part: IMAP BODYSTRUCTURE, then `BODY.PEEK[HEADER]`, every part's `MIME` header and every part at or below the threshold; attachments above it stay at the provider. Such a message is **partial**: it lives in the device folder (`partial/<account>/<id>.manifest.json`, `.skeleton.eml`, `.skeleton.md`), never in the mail folder, and its fetched parts are blobs in `cache/blobs/`. The skeleton is the fetched sections with the left-out parts empty; search, threads, the reader's text, classification and sender rules read it. It is never an original: `originalData` refuses it, export leaves it out and says so (`ExportResult.partial`), the integrity check lists it as partial and never as checked, the attachment library and text extraction mark its left-out parts as not downloaded. It is **completed** by downloading the whole original once (`BODY.PEEK[]`) and storing it as any message, byte for byte, under the same local id (flags, folders, spaces, pins and verdict stay), after which the partial files go; a crash in between leaves the original (recovery and rebuild drop a partial copy that has one) or the partial copy. Only parts MailMIME lists as attachments are ever left out. Index schema 6 marks partial messages and the IMAP section of a left-out part, migrated in place with two `ALTER TABLE`s

**Why.** The `.eml` must be the provider's bytes or nothing (MAIL-003, MAIL-044): IMAP sections cannot be stitched back into a byte-identical original (boundaries, preamble and padding are not in them), so a partial message is kept apart, labelled, and replaced by the real original instead of being rebuilt. Messages at or below the threshold are fetched whole as before, so the common path and its numbers are unchanged. GKM-036

**Links.** MAIL-003, MAIL-044, GKM-036
