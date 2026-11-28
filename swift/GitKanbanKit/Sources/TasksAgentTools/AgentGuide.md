# Tasks: the agent guide

Read this once, completely, before you touch a board. It is everything you need to work on Tasks
boards correctly: how to reach them, how a session starts and ends, the card lifecycle, reviews,
docs, and every command and tool. It was printed by `tasks guide` or returned by the
`get_agent_guide` tool; both give the same text.

One thing outranks this guide: **the board's own rules.** Every board has a contract (the README of
its repository, plus the board's own README and rule files). Read it with `tasks rules <board>` or
`get_board_rules` before your first change on a board (`tasks guide --board <board>` prints this
guide with that board's rules appended). Where the board's rules say something different from this
guide (other lanes, other required fields, other sections), follow the board.

## 1. What Tasks is

Tasks (GitKittie Tasks) is a Kanban board app. Each board is a folder of Markdown cards in a git
repository (or a plain folder): the lanes are folders, each card is a Markdown file with YAML
frontmatter (the machine-readable state: owner, lease, status, links) and a body (Context, Scope,
Handoff, Activity log, …). The people you work for watch the same boards in the app on their Mac
and phone.

The board is the memory between sessions. It is how the next agent, or the person a week later,
finds out what was done, what is half-finished and where to pick up. Keep it current while you
work, not as a report at the end: a session that stops at 80% with an up-to-date card can be picked
up; one with a perfect card written only at the end cannot.

## 2. How to reach it

There are two ways in. Both talk to the Tasks app on this Mac, which reads and writes the boards
for you and opens itself in the background when it is closed.

1. **The `tasks` MCP server** (tools named `list_boards`, `get_card`, `update_card`, …). If your
   session has these tools, use them.
2. **The `tasks` command-line tool**, when you have no such tools. Every tool has a command
   (`tasks list`, `tasks show`, `tasks update`, …), and `tasks raw <tool> '<json>'` calls any tool
   directly. Add `--json` whenever you parse the output.

Rules for both:

- **Every change lands at once.** The app writes each change to the board's repository and commits
  it when the call returns. There is nothing to pull, commit or push, and no copy of the board on
  your disk. A call or command that returns without an error has landed.
- **Never go around the app.** Don't call its HTTP endpoint with curl, don't read or copy its token
  or `connection.json`, and don't edit card files in a clone of the board's repository while the
  app is reachable. If neither the tools nor the command work, say so and ask the person to fix
  the connection (see Exit codes); don't improvise another way in.
- **If you have neither**, tell the person: they can connect agents in Tasks ▸ account menu ▸ Agent
  Access… (one command for Claude Code; "Install Command-Line Tool…" for the `tasks` command).
  Until then this guide can still be pasted to you (Agent Access ▸ Copy Full Guide), but you cannot
  change a board through Tasks. Edit a board's repository directly only when the board's rules or
  your own instructions describe that fallback, and then follow them exactly (they say how to
  commit and push each change).

### Who you are

Every change is recorded under your **agent handle**: in `created_by`, `picked_up_by`, the activity
log and commit messages. With the tools, pass it as `agent`. With the command line, set it once:

```sh
export TASKS_AGENT=claude      # or pass --agent claude on each command
```

Use the canonical handle the board knows you by: `tasks board <board>` (or `get_board`) lists the
board's `users`. If you are on the list, use exactly that id; if you are not, use the short
lowercase handle your instructions give you, and never a display-name variant ("Claude Code",
"claude-opus"). **Never guess or borrow an identity**:
don't act under another agent's or a person's handle. The command line refuses to change anything
without a handle, so nothing is ever recorded under a guessed name.

## 3. The start of every session

Before you write code, in this order:

1. **Find the board.** `tasks boards` (`list_boards`). Board names roughly match the project; the
   project's own `AGENTS.md` / `CLAUDE.md` often names its board and card id prefix. Use the
   `board` value exactly as listed (or just the name when it is unambiguous).
2. **Read its rules** once: `tasks rules <board>` (`get_board_rules`). They define the lanes, the
   fields and their allowed values, the card template and the lifecycle for this board. Then
   `tasks board <board>` (`get_board`) for the lanes, priorities, types, epics, users and the card
   id prefix.
3. **See where work was left off:** `tasks list --board <board> --lane in-progress`, then
   `tasks show <card>` for each card that could be yours. Look at `picked_up_by`,
   `claim_expires_at`, the Handoff section and the end of the Activity log.
4. **See the queue:** `tasks list --board <board> --lane todo`. Skim recent Done cards when you need
   to know what was already tried.
5. **Act on answered reviews:** `tasks reviews --board <board>` (`list_reviews`) lists decisions and
   answers the reviewer gave that nobody has acted on yet. Handle them (section 6).
6. **Pick the card.** If the request matches a card, work that card. If it doesn't, create one
   (section 4). Say which card you are on in your first real reply, so the person can correct you
   before you build the wrong thing.
7. **Claim it** before you implement anything (section 5).

Skip the card only for trivial work: a typo, a question, reading code, a throwaway experiment.
Anything a future session would need context on gets a card, and anything blocked, deferred or
deliberately left undone gets one *especially*: work you decided not to do is the most valuable
thing to record and the thing most often lost.

## 4. Cards

### What a card holds

The **frontmatter** is the state. The standard contract's fields (your board's rules are
authoritative):

- `id` (immutable, unique, with the board's prefix, e.g. `PROJ-012`), `title` (the outcome, not an
  activity), `project`, `status` (always the status of the lane the card is in).
- `priority`, `type`, `epic`, `assignee`, `tags`: values from the board's own lists (`tasks board`).
  `assignee` is a routing hint, not a lock: prefer cards assigned to you or to nobody.
- Ownership and lease: `picked_up_by`, `picked_up_at`, `last_heartbeat_at`, `claim_expires_at`.
- Review and testing: `reviewer`, `review_started_at`, `review_outcome` (`approved` |
  `changes-requested`), `review_completed_at`; `testing_owner`, `testing_started_at`,
  `testing_artifact`, `testing_outcome` (`passed` | `failed`), `testing_completed_at`.
- `completed_by`, `completed_at`; `blocked` and one concrete `blocked_reason`; `depends_on` (ids that
  must be Done first: real execution gates only, not related topics).
- Links to the work: `repository`, `working_branch`, `pull_request`, `commits` (implementation SHAs
  only), optional `due` (`YYYY-MM-DD`).
- `created_by`, `created_at`, `updated_at`: set by the app. Never rewrite `created_*`.
- `read_by` / `read_at`: **never set or clear these.** Only the person sets them, in the app, when
  they have read a finished card. A change bumps `updated_at`, which shows the card as unread
  again, so only change a finished card for a real reason.

Timestamps are UTC ISO-8601 ending in `Z`; empty values are `null`, not `""`.

The **body** follows the board's template (`tasks rules` shows it). The standard sections are
**Context** (why, with evidence), **Outcome** (the one result this card owns), **Scope**, **Out of
scope**, **Acceptance criteria** (checks someone else could verify), **Verification** (the exact
automated and manual checks), **Handoff** (branch, commits, PR, artifact, result, residual risk) and
**Activity log** (append-only).

### Creating a card

```sh
tasks create --board MyProject --title "Fix the sync badge" --priority P2 --type fix --body-file card.md
```

The app gives it the next free id and puts it in the to-do lane, starting from the board's
template; without a body the template's sections are kept for you to fill in. Fill in every
section. Use only values the board defines; the app refuses others and names the allowed ones. If a
value really should exist, it has to be added to the board's README first: ask the person.

- **One card, one coherent outcome.** Two deliverables that could ship separately are two cards.
- **Check before you create:** `tasks list --board <board> --query <words>` so you don't file a
  duplicate. Check `tasks boards` before `tasks create-board`.
- **Problems you find but don't fix now** get their own card in To do, with the evidence (file,
  line, what breaks) and a priority, and you mention them to the person. Don't silently absorb them
  and don't widen your card to cover them.
- Never put credentials, tokens, private keys, `.env` contents, personal data or production
  payloads on a card, an attachment, a doc or a review. Say where a secret lives; never paste it.

## 5. The card lifecycle

Lanes and their statuses come from the board (`tasks board`). The standard ones, and what they mean:

| Lane | Status | Means |
|---|---|---|
| To do | `todo` | Specified, unclaimed. |
| In Progress | `in-progress` | Claimed; exactly one owner. Blocked work stays here with `blocked: true`. |
| In Review | `in-review` | Implemented and linked (branch, commits, PR); waiting for independent review. |
| Testing | `testing` | Review passed; the exact reviewed artifact is being tested. |
| Done | `done` | Every acceptance criterion checked, verification recorded, no blocker left. |

Move a card with `tasks move <card> <lane>` (or `update_card` with `lane`); the status follows the
lane, and the app refuses a `status` that doesn't match its lane. The id and file name never change.

### Claim before you implement

```sh
tasks claim PROJ-12 --branch feat/sync-badge --hours 8
```

A claim records you in `picked_up_by` with `picked_up_at`, `last_heartbeat_at` and a lease in
`claim_expires_at` (default 24 hours; use a shorter one for small work), records `--branch` as
`working_branch`, and moves the card to In Progress. Before claiming, check that every card in `depends_on` is Done.

- **The app refuses to claim a card someone else holds** with an unexpired lease ("… is already
  claimed by … Choose another card."). Choose another card. Never edit `picked_up_by` or the lease
  of someone else's card to get around it.
- **An expired lease is not permission.** The app will let you claim a card whose lease has run
  out, but the contract says time alone never authorizes a reclaim: only reclaim when the owner has
  explicitly given it up or cannot be reached, after you have looked at their branch, PR, the
  card's history and any sign the work is still running. Record what you checked, the work you
  preserved and why you reclaim in the Activity log. If the work may still be active, set
  `blocked` for coordination instead.
- **Renew your lease (the heartbeat)** before it runs out on long work: claim the card again
  (`tasks claim <card> --hours <n>`). For the card's owner that refreshes `last_heartbeat_at` and
  `claim_expires_at` and keeps `picked_up_at`.

### Keep the card current while you work

Update it when something happens, not at the end:

- **The plan changes**: scope grew, an approach failed, the cause was elsewhere. Amend Scope / Out
  of scope and log it. Record each **rejected approach and why**, so the next agent doesn't repeat
  it.
- **You are blocked**: set `blocked` with one concrete reason. The card stays in its lane.

  ```sh
  tasks update PROJ-12 --set blocked=true --set "blocked_reason=Waiting for the API key" -m "Blocked on the API key."
  ```

  To resume, set `blocked=false` and `blocked_reason=null` and log the resolution. Never move work
  to Done because it is blocked or no longer wanted.
- **You commit or open a PR**: record `commits`, `pull_request`, `working_branch`.

The **Activity log** is append-only: add to it with `tasks comment <card> "<text>"` or
`--activity "<text>"` on any update (the app adds the time and your handle). People follow along in
the app's progress list, which shows each card's **last activity line** under its title, so write
every entry to stand on its own and say what is happening now ("blocked on the decoder; trying a
12-frame cycle"), not "updated card".

To change the body, read it (`tasks show <card> --json`, field `text`), edit the Markdown, and write
the whole body back (`tasks update <card> --body-file card.md`): the body is replaced, not merged.
Keep the Activity log entries that were there.

### Hand off and move on

When the implementation is done:

1. Run the checks from Verification; tick the acceptance criteria you met.
2. Fill in **Handoff**: branch, commits, PR, artifact or deployment, the result, and the residual
   risk (what you could not verify, and why).
3. `tasks move <card> review --activity "<what is ready and where>"`.

After that, by the standard contract:

- **Review** is independent: the reviewer records `reviewer` and `review_started_at`, then
  `review_outcome`. Don't review and approve your own card. Changes requested → the card goes back
  to In Progress, keeping the review history.
- **Testing**: after approval, the testing owner sets `testing_owner`, `testing_started_at` and the
  exact `testing_artifact`, and moves the card to Testing. A failure sends it back to In Progress
  with the evidence.
- **Done**: only when every acceptance criterion is checked and verification is recorded; set
  `completed_by` and `completed_at`. Never move a card straight from To do to Done. Done is history:
  a regression gets a new card that links the old one, not a reopened card.
- Moving a card on someone's behalf (to Testing, to Done) is their call or the board's rules' call;
  if you are not sure you may, ask.

### Never leave a claimed card silently stale

If you stop for any reason (out of context, the person changed topic, end of session), leave the
card describing reality before you go:

- what is committed and pushed (branch, SHAs, PR),
- what is not (uncommitted or unpushed work, and where it is),
- the next concrete step,

as an activity entry and in Handoff. If you are giving the card up, say so in the log and clear
your claim (`--set picked_up_by=null --set claim_expires_at=null`) so someone else can take it.

## 6. Reviews: asking the person

When you need the person to **judge something** (images, icons, screenshots, models, audio, video)
or to **decide something** (an approach, a product question, a name), ask through a review request
instead of in chat, when it can wait. The app shows it to them as a form, on Mac and phone, and
writes their answer back to the board.

- **Questions** are for decisions: each has options, `select: one` (default) or `many`, and
  `other: true` when they may write their own answer. Never turn options into little files to
  approve.
- **Items** are files to approve or reject (`kind`: image, model, audio, animation, video, other).
  Items in one `group` are shown side by side; `pick_one` makes the reviewer choose one of them. A
  model or video needs a `preview` PNG.
- **Recommend an answer.** There is no separate field for it: put the option you recommend first,
  say "(recommended)" in its label, and give the trade-off of every option in its `detail`.
- One request per round of related work; several questions in one request read as one form. Put the
  background in the question's `detail` (Markdown).
- **How loudly it is announced:** `"notify"` (`notify:` in the request's frontmatter). `urgent` is
  time-sensitive and breaks through the person's Focus: use it only when work is blocked on the
  answer. `normal` (the default, also when left out) is an ordinary notification. `silent` sends no
  notification: the request only counts on the badge and in the Reviews list (an FYI, a decision that
  can wait for the next look). To change it later: `create_review` with `"request"` and `"notify"`.

Creating one goes through `create_review` (from the command line: `tasks raw create_review`, with
the JSON on standard input):

```sh
tasks raw create_review --board MyProject - <<'JSON'
{
  "card": "PROJ-12",
  "title": "Sync badge: two decisions",
  "question": "Pick the badge style and when it shows.",
  "questions": [
    {
      "id": "style",
      "question": "Which badge style?",
      "detail": "The toolbar has room for one of these.",
      "options": [
        {"id": "dot", "label": "Dot (recommended)", "detail": "Quiet; matches the sidebar."},
        {"id": "count", "label": "Count", "detail": "Shows how many changes wait; wider."}
      ]
    },
    {
      "id": "when",
      "question": "When does it show?",
      "select": "many",
      "other": true,
      "options": [
        {"id": "offline", "label": "While offline"},
        {"id": "conflict", "label": "On a conflict"}
      ]
    }
  ]
}
JSON
```

Files are sent base64-encoded in `items` (`"content_base64": "<base64 of the file>"`, e.g. from
`base64 -i after.png`). To add to an existing request (a redo), pass `"request": "<id>"` instead of
a title, and set `"revises": "<old item id>"` on the new item.

Then **log the request on the card** (and in Handoff if the work waits on it), and carry on with
other work. If nothing can move until the answer comes, say so on the card. To wait for it:
`tasks review wait --card PROJ-12 --timeout 240` (`wait_for_reviews`) returns as soon as something
is answered, or an empty list when the time is up (call it again).

**When answers come back** (`tasks reviews`, state `to_handle`):

- A question has `answer` (the chosen option ids), `answer_labels`, maybe `answer_other`, and
  `answered_by` / `answered_at`. Act on it, then record that you did:
  `tasks review handle <request> <question id>`. The reviewer can change an answer until you handle
  it; after that it is fixed, so handle it only once you have acted on it.
- An item has `status` `approved`, `rejected` or `changes-requested`, with `decided_by` /
  `decided_at` and `comments`. Approved → put the file where it ships, then
  `tasks review handle <request> <item> --shipped-to <path>`. Rejected → don't use it; read the
  comments; make a new one if the card still needs it. Changes requested → add a new item with
  `revises`, then handle the old one.
- Handling sets `handled_at`. Never set `approved`, an answer, or any of the reviewer's fields
  yourself, and only ever append to `comments`.
- **Closing:** a request whose every item and question is decided and handled removes itself (pass
  `--keep` to keep it). `tasks review close <request>` removes a finished one; the app refuses while
  something still waits, unless `--force` (only when the request is really obsolete).

## 7. Docs, attachments and the activity log

- **Docs.** A board's plans, specs and decisions live in its documentation pages (the board's
  README text and `docs/*.md`): `tasks docs --board <board>`, `tasks docs show <path>`,
  `tasks docs search <words>`. Read the relevant ones before you plan. To write: a new page with
  `tasks raw write_doc '{"title": "…", "text": "…"}'`; to change a page, read it first and pass the
  exact text you read as `"replaces"` (the app refuses if the page changed since: read it again and
  redo your change). Prefer adding to a page or writing a new one over rewriting what the owner
  wrote. The README is the board's configuration and cannot be deleted.
- **Attachments.** `tasks attach <card> <file>` (`attach_file`) stores a file next to the board
  (`attachments/<CARD-ID>/`), shown large on the card. Attach a screenshot when it shows the result
  faster than words: UI before/after, a visual bug, a rendered asset. PNG or JPEG, descriptive file
  names (`after-small-phone.png`), under about 2 MB, mentioned in the log or Handoff. Things that
  need an approve/reject go through a review instead. If `tasks` says it cannot read the file (a
  sandboxed copy), pass it on standard input: `tasks attach <card> - --name shot.png < shot.png`.
- **Activity log.** `tasks comment <card> "<text>"`, or `--activity` / `-m` on `update` and `move`
  (`activity` on `update_card`). One sentence per event, standing on its own.

## 8. Rules at a glance

What the app enforces (a call that breaks these is refused, exit code 1):

- Field values must be the board's own (`priority`, `type`, `epic`, `assignee`, `status`).
- `status` follows the lane; the id never changes; fields are strings, numbers, booleans, `null` or
  lists of strings.
- No claim over someone else's unexpired lease.
- A doc is only replaced when you pass the text you read; a review is only closed when finished.
- No change without an agent handle (command line).

What the contract asks of you (nobody stops you, so it is on you):

- Read the board's rules before your first change; they win over this guide.
- Claim before implementing; one owner per card; don't touch other agents' claims or cards they
  are working on, except to add a comment.
- Keep the card current while working; record rejected approaches; never leave a claim silently
  stale.
- One card per coherent outcome; a new card for each real problem you find but don't fix.
- Never set `read_by` / `read_at`; never set the reviewer's fields; never move To do → Done; Done is
  history.
- No secrets or personal data anywhere on the board.
- Never reach the board around the app (curl, the token, editing card files while the app works).

## 9. Command reference

Card commands find the board from the card's id prefix (`PROJ-12` → the board that numbers PROJ
cards), so they need no `--board`. Everything else needs `--board <board>` or `TASKS_BOARD`.

Environment:

{{environment}}

{{commands}}

## 10. Exit codes and errors

With `--json`, an error is printed to standard error as `{"error": "…", "kind": "…",
"exit_code": n}`.

{{exit-codes}}

Messages you may meet, and what to do:

- `Say who you are: --agent <handle>, or set TASKS_AGENT` (2): set `TASKS_AGENT` (section 2).
- `say which board: --board <board>` (2): give `--board`; `tasks boards` lists them.
- `No board "…"` / `No card "…"` / `No lane "…"` (1): check the name with `tasks boards`,
  `tasks list`, `tasks board`; the message lists what exists.
- `Cards numbered … are on more than one board` (2) or `Could not tell which board numbers …
  cards` (1): pass `--board`.
- `… is already claimed by … Choose another card.` (1): it is someone else's; pick another card.
- `"…" is not one of this board's priorities/types/epics/users …` (1): use one of the listed values;
  a new value has to be added to the board's README first (ask the person).
- `status "…" does not match the lane …` (1): move the card with `--lane` / `tasks move` instead.
- `… changed since you read it` (1, docs): read the page again and redo your change on the new text.
- `Could not read <file> …` (2): this copy of `tasks` is sandboxed; pass the file on standard input
  (`--body-file - < card.md`, `tasks attach <card> - --name <name> < <file>`).
- `The Tasks app is not running …` (3), token refused (4), Agent Access not set up (5): ask the
  person (see the table). Don't retry another way.

## 11. Tool reference (MCP)

The same operations as tools of the `tasks` MCP server. The command line calls these tools; every
tool can also be called with `tasks raw <tool> '<json>'`, and `tasks tools <tool>` prints its
argument schema.

{{tools}}
