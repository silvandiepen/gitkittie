---
id: MAIL-133
title: "**Tasks takes `gitkittie-tasks://new?title=&body=` from any app** (`NewTaskRequest`,..."
date: 2026-11-27
status: proposed
---

# MAIL-133: **Tasks takes `gitkittie-tasks://new?title=&body=` from any app** (`NewTaskRequest`,...

**Decision.** **Tasks takes `gitkittie-tasks://new?title=&body=` from any app** (`NewTaskRequest`, `AppModel.openTaskRequest` in GitKanbanKit): on the open board's first open lane, else after asking which board (now on iPhone and iPad too), and while the sheet is up it joins it without replacing what was typed. It never saves on its own; title cut at 300 characters, description at 10,000, control characters out. A Tasks card opens `gitkittie-mail:` links beside http, https and mailto

**Why.** Any app or web page can open a URL, so a URL may only ever propose. GKM-033

**Links.** GKM-033
