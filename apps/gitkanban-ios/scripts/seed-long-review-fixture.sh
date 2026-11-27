#!/bin/sh
# Seed a local-folder board with one long review request (60 files, a question and Markdown
# notes with headings, pictures and a table), on a booted simulator that already has the app
# installed. UITests/ReviewLongRequestUITests needs this. It replaces the app's added boards
# in the App Group (as seed-select-fixture.sh does).
#
#   scripts/seed-long-review-fixture.sh <simulator-udid>                 # seed, prints the fixture folder
#   scripts/seed-long-review-fixture.sh <simulator-udid> --from <folder>  # also add every request in
#                                                                         # <folder>/<Project>/review/
#   scripts/seed-long-review-fixture.sh <simulator-udid> --clean          # remove it again
set -eu
SIM="$1"
GROUP=$(xcrun simctl get_app_container "$SIM" app.hakobs.gitkanban groups | cut -f2)
FIX="$GROUP/long-review-fixture"
PREFS="$GROUP/Library/Preferences/group.app.hakobs.gitkanban.plist"
rm -rf "$FIX" "$PREFS"
[ "${2:-}" = "--clean" ] && exit 0

REQ="$FIX/Tasks/Long/review/LONG-1-long-review"
mkdir -p "$FIX/Tasks/Long/1. To do" "$FIX/Tasks/Long/5. Done" "$REQ" "$(dirname "$PREFS")"
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
printf -- '---\nconfig: project\nproject: Long\nlanes: []\n---\n' > "$FIX/Tasks/Long/README.md"
printf -- '---\nid: LONG-1\ntitle: Long review\nproject: Long\nstatus: todo\n---\n\n# Long review\n' > "$FIX/Tasks/Long/1. To do/LONG-1-long-review.md"

python3 - "$REQ" <<'PY'
import struct, sys, zlib
folder = sys.argv[1]
def png(path, rgb, size=96):
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
items = []
for i in range(60):
    name = f"tile-{i + 1:02d}"
    png(f"{folder}/{name}.png", ((i * 37) % 255, (i * 91) % 255, (i * 53) % 255))
    status = "approved" if i < 6 else "pending"
    group = ["trees", "rocks", "plants"][i // 20]
    items.append(f"""  - id: {name}
    file: {name}.png
    group: {group}
    note: "Tile {i + 1}: made by `tools/tiles.py`, **original** colours."
    status: {status}
    comments: []""")
png(f"{folder}/overview.png", (40, 120, 90), 160)
with open(f"{folder}/review.md", "w") as handle:
    handle.write("""---
config: review
id: LONG-1-long-review
card: LONG-1
title: Long review, round 1
question: Approve or reject each tile. The `trees` set is **first**.
requested_by: claude
requested_at: 2026-11-26T10:00:00Z
items:
""" + "\n".join(items) + """
questions:
  - id: order
    question: Which set ships first?
    select: one
    options: [trees, rocks, plants]
---

## How these were made

Made by `tools/tiles.py` from the **original** palette. See [the notes](notes.md).

![Overview of every tile](overview.png)

| Set | Tiles |
|-----|-------|
| trees | 20 |
| rocks | 20 |

## What to look for

1. Colours that clash.
2. Tiles that repeat.
""")
PY

BOARDS='[{"folder": "Tasks/Long", "name": "Long", "laneCount": 2, "memberCount": 0, "hasBacklog": False}]'
if [ "${2:-}" = "--from" ]; then
  # Real requests to look at: each project folder becomes a board of its own.
  for project in "$3"/*/; do
    name=$(basename "$project")
    [ -d "$project/review" ] || continue
    mkdir -p "$FIX/Tasks/$name/1. To do" "$FIX/Tasks/$name/5. Done"
    printf -- '---\nconfig: project\nproject: %s\nlanes: []\n---\n' "$name" > "$FIX/Tasks/$name/README.md"
    cp -R "$project/review" "$FIX/Tasks/$name/review"
    BOARDS=$(python3 -c "import sys; b=eval(sys.argv[1]); b.append({'folder': 'Tasks/'+sys.argv[2], 'name': sys.argv[2], 'laneCount': 2, 'memberCount': 0, 'hasBacklog': False}); print(repr(b))" "$BOARDS" "$name")
  done
fi

# The same JSON `AddedRepo` encodes to, stored as Data under the key AppModel reads.
python3 - "$PREFS" "$FIX" "$BOARDS" <<'PY'
import json, plistlib, sys
prefs, fixture, boards = sys.argv[1], sys.argv[2], eval(sys.argv[3])
repo = {"namespace": "folder", "name": "Long review fixture", "branch": "", "isPrivate": True,
        "boards": boards, "kind": {"localFolder": {"path": fixture}}}
with open(prefs, "wb") as handle:
    plistlib.dump({"gitkanban.addedReposV2": json.dumps([repo]).encode(),
                   "gitkanban.storageMigratedToGroup": True}, handle)
PY
echo "$FIX"
