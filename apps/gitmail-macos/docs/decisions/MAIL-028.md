---
id: MAIL-028
title: "A chosen mail folder is remembered as a security-scoped bookmark and gets its own..."
date: 2026-11-24
status: proposed
---

# MAIL-028: A chosen mail folder is remembered as a security-scoped bookmark and gets its own...

**Decision.** A chosen mail folder is remembered as a security-scoped bookmark and gets its own device state (`<Application Support>/Mail/folders/<hash of its path>/`); the default `Documents/Mail` keeps `<Application Support>/Mail/`. The accounts shown are the ones in the open folder

**Why.** The index and mapping describe one folder's messages; sharing them across folders would make the sync skip mail. GKM-010

**Links.** GKM-010
