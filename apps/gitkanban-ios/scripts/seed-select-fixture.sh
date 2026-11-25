#!/bin/sh
# Seed a local-folder board with a review request of several files, on a booted simulator
# that already has the app installed. UITests/ReviewSelectUITests needs this.
# It replaces the app's added boards in the App Group (as seed-question-fixture.sh does).
#
#   scripts/seed-select-fixture.sh <simulator-udid>          # seed, prints the fixture folder
#   scripts/seed-select-fixture.sh <simulator-udid> --clean  # remove it again
set -eu
SIM="$1"
GROUP=$(xcrun simctl get_app_container "$SIM" app.hakobs.gitkanban groups | cut -f2)
FIX="$GROUP/select-fixture"
PREFS="$GROUP/Library/Preferences/group.app.hakobs.gitkanban.plist"
rm -rf "$FIX" "$PREFS"
[ "${2:-}" = "--clean" ] && exit 0

REQ="$FIX/Tasks/Pets/review/PETS-2-icons"
mkdir -p "$FIX/Tasks/Pets/1. To do" "$FIX/Tasks/Pets/5. Done" "$REQ" "$(dirname "$PREFS")"
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
printf -- '---\nid: PETS-2\ntitle: Pet icons\nproject: Pets\nstatus: todo\n---\n\n# Pet icons\n' > "$FIX/Tasks/Pets/1. To do/PETS-2-pet-icons.md"
cat > "$REQ/review.md" <<'YAML'
---
config: review
id: PETS-2-icons
card: PETS-2
title: Pet icons, round 1
requested_by: claude
requested_at: 2026-11-25T10:00:00Z
items:
  - id: icon-cat
    file: cat.png
    status: pending
    comments: []
  - id: icon-dog
    file: dog.png
    status: pending
    comments: []
  - id: icon-fish
    file: fish.png
    status: pending
    comments: []
  - id: bowl-red
    file: bowl-red.png
    group: bowl
    pick: one
    status: pending
    comments: []
  - id: bowl-blue
    file: bowl-blue.png
    group: bowl
    pick: one
    status: pending
    comments: []
---
YAML

# Small plain-colour PNGs, so the thumbnails have something to show.
python3 - "$REQ" <<'PY'
import struct, sys, zlib
def png(path, rgb):
    size = 64
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
folder = sys.argv[1]
for name, rgb in [("cat", (240, 160, 60)), ("dog", (150, 110, 70)), ("fish", (70, 160, 230)),
                  ("bowl-red", (220, 60, 60)), ("bowl-blue", (60, 90, 220))]:
    png(f"{folder}/{name}.png", rgb)
PY

# The same JSON `AddedRepo` encodes to, stored as Data under the key AppModel reads.
python3 - "$PREFS" "$FIX" <<'PY'
import json, plistlib, sys
prefs, fixture = sys.argv[1], sys.argv[2]
repo = {"namespace": "folder", "name": "Select fixture", "branch": "", "isPrivate": True,
        "boards": [{"folder": "Tasks/Pets", "name": "Pets", "laneCount": 2, "memberCount": 0, "hasBacklog": False}],
        "kind": {"localFolder": {"path": fixture}}}
with open(prefs, "wb") as handle:
    plistlib.dump({"gitkanban.addedReposV2": json.dumps([repo]).encode(),
                   "gitkanban.storageMigratedToGroup": True}, handle)
PY
echo "$FIX"
