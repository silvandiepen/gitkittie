#!/bin/sh
# Seed a local-folder board into the App Group the app and its share extension share, on a
# booted simulator that already has the app installed. UITests/ShareScreenshotUITests needs
# this: the extension only offers boards that are already added.
#
#   scripts/seed-share-fixture.sh <simulator-udid>          # seed, prints the fixture folder
#   scripts/seed-share-fixture.sh <simulator-udid> --clean  # remove it again
set -eu
SIM="$1"
GROUP=$(xcrun simctl get_app_container "$SIM" app.hakobs.gitkanban groups | cut -f2)
FIX="$GROUP/share-fixture"
PREFS="$GROUP/Library/Preferences/group.app.hakobs.gitkanban.plist"
rm -rf "$FIX" "$PREFS"
[ "${2:-}" = "--clean" ] && exit 0

mkdir -p "$FIX/Tasks/Pets/1. To do" "$FIX/Tasks/Pets/5. Done" "$(dirname "$PREFS")"
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

# The same JSON `AddedRepo` encodes to, stored as Data under the key AppModel reads.
python3 - "$PREFS" "$FIX" <<'PY'
import json, plistlib, sys
prefs, fixture = sys.argv[1], sys.argv[2]
repo = {"namespace": "folder", "name": "Share fixture", "branch": "", "isPrivate": True,
        "boards": [{"folder": "Tasks/Pets", "name": "Pets", "laneCount": 2, "memberCount": 0, "hasBacklog": False}],
        "kind": {"localFolder": {"path": fixture}}}
with open(prefs, "wb") as handle:
    plistlib.dump({"gitkanban.addedReposV2": json.dumps([repo]).encode(),
                   "gitkanban.storageMigratedToGroup": True}, handle)
PY
echo "$FIX"
