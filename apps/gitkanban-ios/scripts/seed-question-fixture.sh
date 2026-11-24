#!/bin/sh
# Seed a local-folder board with a review request that asks questions, on a booted
# simulator that already has the app installed. UITests/ReviewQuestionsUITests needs this.
# It replaces the app's added boards in the App Group (as seed-share-fixture.sh does).
#
#   scripts/seed-question-fixture.sh <simulator-udid>          # seed, prints the fixture folder
#   scripts/seed-question-fixture.sh <simulator-udid> --clean  # remove it again
set -eu
SIM="$1"
GROUP=$(xcrun simctl get_app_container "$SIM" app.hakobs.gitkanban groups | cut -f2)
FIX="$GROUP/question-fixture"
PREFS="$GROUP/Library/Preferences/group.app.hakobs.gitkanban.plist"
rm -rf "$FIX" "$PREFS"
[ "${2:-}" = "--clean" ] && exit 0

mkdir -p "$FIX/Tasks/Pets/1. To do" "$FIX/Tasks/Pets/5. Done" "$FIX/Tasks/Pets/review/PETS-1-food" "$(dirname "$PREFS")"
cat > "$FIX/Tasks/README.md" <<'YAML'
---
config: board
lanes:
  - id: todo
    name: To do
    folder: "1. To do"
    status: todo
  - id: done
    name: Done
    folder: "5. Done"
    status: done
    terminal: true
---
YAML
printf -- '---\nconfig: project\nproject: Pets\nlanes: []\n---\n' > "$FIX/Tasks/Pets/README.md"
printf -- '---\nid: PETS-1\ntitle: Feed the cat\nproject: Pets\nstatus: todo\n---\n\n# Feed the cat\n' > "$FIX/Tasks/Pets/1. To do/PETS-1-feed-the-cat.md"
cat > "$FIX/Tasks/Pets/review/PETS-1-food/review.md" <<'YAML'
---
config: review
id: PETS-1-food
card: PETS-1
title: Food and toys for the cat
requested_by: claude
requested_at: 2026-11-24T10:00:00Z
questions:
  - id: food
    question: Which food should the cat get?
    detail: |-
      She has been **picky** lately.

      The vet suggested fish twice a week.
    select: one
    other: true
    options:
      - id: fish
        label: Fish
        detail: She likes it, but it costs more.
      - id: chicken
        label: Chicken
        detail: Cheaper, and she eats it most days.
    answer: []
    comments: []
  - id: toys
    question: Which toys should we buy?
    select: many
    other: true
    options:
      - id: mouse
        label: A toy mouse
      - id: ball
        label: A ball with a bell
      - id: laser
        label: A laser pointer
        detail: Some cats get **frustrated** without something to catch.
    answer: []
    comments: []
---
YAML

# The same JSON `AddedRepo` encodes to, stored as Data under the key AppModel reads.
python3 - "$PREFS" "$FIX" <<'PY'
import json, plistlib, sys
prefs, fixture = sys.argv[1], sys.argv[2]
repo = {"namespace": "folder", "name": "Question fixture", "branch": "", "isPrivate": True,
        "boards": [{"folder": "Tasks/Pets", "name": "Pets", "laneCount": 2, "memberCount": 0, "hasBacklog": False}],
        "kind": {"localFolder": {"path": fixture}}}
with open(prefs, "wb") as handle:
    plistlib.dump({"gitkanban.addedReposV2": json.dumps([repo]).encode(),
                   "gitkanban.storageMigratedToGroup": True}, handle)
PY
echo "$FIX"
