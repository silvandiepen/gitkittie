# Decisions

Proposed, subject to validation.

**One file per decision**, in [`decisions/`](./decisions/): `MAIL-NNN.md`, numbered in the order they
were taken. There is no table here on purpose: a shared table makes every parallel PR conflict. List
them with `node scripts/decisions-index.mjs` (from the repo root), or browse the folder.

## Adding a decision

1. Take the next free number (`ls docs/decisions | tail -1`) and create `docs/decisions/MAIL-NNN.md`.
   If a parallel PR took the same number, rename yours when it merges.
2. Copy this shape (the front matter is checked by `npm run check`):

   ```md
   ---
   id: MAIL-135
   title: "Short name of the decision"
   date: 2026-11-28
   status: proposed
   ---

   # MAIL-135: Short name of the decision

   **Decision.** What was decided.

   **Why.** The reason, and what was rejected.

   **Links.** GKM-nnn, MAIL-nnn
   ```

   `status` is `proposed`, `accepted`, `open` or `superseded`. Longer write-ups go under further
   headings in the same file.
3. Never edit this file to add a row, and never add the decision to a shared list.

`MAIL-017` carries the long protocol-libraries write-up (GKM-002) under its own heading.
