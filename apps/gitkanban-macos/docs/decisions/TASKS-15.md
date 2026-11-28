---
id: TASKS-15
section: "§ 15"
title: "Review screens: filter, notes as Markdown, lenient frontmatter (GITKITTIE-106/107/108)"
date: 2026-11-27
status: accepted
---

# § 15. Review screens: filter, notes as Markdown, lenient frontmatter (GITKITTIE-106/107/108)

**Decision.**

- **Filter.** Both apps show a request through one filter, Waiting, Answered or All, with counts
  (`ReviewFilter`, `ReviewRequest.hiddenIDs(for:)` in `swift/GitKittieKit`). It replaces "Only
  Waiting" (Mac) and "Show Answered" (iOS) and is remembered under `reviewsFilter`. What it hides
  is fixed when the request opens or the filter changes, so a file you just decided stays put.
  "Answered" means the contract's decision or answer is written (`status` not `pending`, a
  question with `answered_at`); `handled_at` does not make it wait again.
- **Pick-one groups only stay together.** Under Waiting, decided options stay on show only in a
  pick-one group that still waits. Before, any group did, so a request whose files are all
  grouped (MESSIO-008: 4 groups, 232 files) could not be filtered at all.
- **Order.** Questions first, then files group by group (`ReviewRequest.entries`), on both
  apps; Next Waiting (⌘J on the Mac, ⏩ in the iPhone header) goes on from the last thing you
  worked on.
- **Notes.** The Markdown under the frontmatter is drawn as Markdown with its pictures
  (`MarkdownBlocks` `.images`, `swift/TasksUI/ReviewNotes.swift`): folded to its start on the
  Mac when long, a Notes sheet on iPhone and iPad. The Mac used to print it as raw text.
- **Hand-written frontmatter.** When `review.md` is not valid YAML, the two slips seen in real
  requests (quotes inside a double-quoted value, `: ` inside a plain value) are mended line by
  line outside block scalars before giving up (`Review.composeLeniently`); the next reviewer
  write saves valid YAML. Anything else shows "This request can't be read" with the YAML error
  and its line, instead of an empty request.
- **Scrolling.** Cards are kept cheap to make (no AppKit checkbox, the comment field only when
  wanted, saving state read by the buttons alone), pictures are decoded off the main thread at
  the size shown and kept (`ReviewImageCache`), and the notes are a lazy stack. Measured on real
  requests: see GITKITTIE-106.

**Status.** Accepted.
