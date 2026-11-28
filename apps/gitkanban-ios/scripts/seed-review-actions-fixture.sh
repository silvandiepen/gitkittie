#!/bin/sh
# Seed a local-folder board with review requests that carry actions, a browser check and `for:`,
# on a booted simulator that already has the app installed. UITests/ReviewActionsCheckUITests
# needs this. It replaces the app's added boards in the App Group (as seed-select-fixture.sh does).
#
# - "Site onboarding, round 1": accepting its last waiting file moves PETS-1 to Testing.
# - "Onboarding page check" (for Sil): a browser check of a page bundled as a data: URL (no
#   network), at phone and desktop, light and dark; the page prints its viewport width and
#   colour scheme, and has a button that says "Tapped" once tapped.
# - "Copy for the store" (for Herma): read-only for Sil, comments allowed.
# Nobody on the board matches the simulator's login, so the Reviews list asks "Which one are you?".
#
#   scripts/seed-review-actions-fixture.sh <simulator-udid>          # seed, prints the fixture folder
#   scripts/seed-review-actions-fixture.sh <simulator-udid> --clean  # remove it again
set -eu
SIM="$1"
GROUP=$(xcrun simctl get_app_container "$SIM" app.hakobs.gitkanban groups | cut -f2)
FIX="$GROUP/review-actions-fixture"
PREFS="$GROUP/Library/Preferences/group.app.hakobs.gitkanban.plist"
rm -rf "$FIX" "$PREFS"
[ "${2:-}" = "--clean" ] && exit 0

BOARD="$FIX/Tasks/Pets"
mkdir -p "$BOARD/1. To do" "$BOARD/2. In Progress" "$BOARD/3. In Review" "$BOARD/4. Testing" "$BOARD/5. Done" \
  "$BOARD/review/PETS-1-site" "$BOARD/review/PETS-3-page" "$BOARD/review/PETS-4-copy" "$(dirname "$PREFS")"
cat > "$FIX/Tasks/README.md" <<'YAML'
---
config: board
lanes:
  - { id: todo, name: To do, folder: "1. To do", status: todo }
  - { id: in-progress, name: In Progress, folder: "2. In Progress", status: in-progress }
  - { id: in-review, name: In Review, folder: "3. In Review", status: in-review }
  - { id: testing, name: Testing, folder: "4. Testing", status: testing }
  - { id: done, name: Done, folder: "5. Done", status: done, terminal: true }
users:
  - { id: sil, name: Sil, kind: human, github: nobody-on-this-simulator }
  - { id: herma, name: Herma, kind: human }
  - { id: claude, name: Claude, kind: agent }
---
YAML
printf -- '---\nconfig: project\nproject: Pets\nlanes: []\n---\n' > "$BOARD/README.md"
for card in "PETS-1:Site onboarding" "PETS-3:Onboarding page" "PETS-4:Store copy"; do
  ID=${card%%:*}; TITLE=${card#*:}
  cat > "$BOARD/3. In Review/$ID.md" <<CARD
---
id: $ID
title: $TITLE
project: Pets
status: in-review
assignee: claude
updated_at: 2026-11-27T09:00:00Z
picked_up_by: claude
claim_expires_at: 2099-01-01T00:00:00Z
reviewer: null
review_outcome: null
review_completed_at: null
---

# $TITLE

## Activity log

- 2026-11-27T09:00:00Z — \`claude\` created the task.
CARD
done

TOMORROW=$(date -v+1d +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d)
cat > "$BOARD/review/PETS-1-site/review.md" <<YAML
---
config: review
id: PETS-1-site
card: PETS-1
title: Site onboarding, round 1
question: Approve the badge to finish this round.
requested_by: claude
requested_at: 2026-11-27T10:00:00Z
due: $TOMORROW
on_accept: { to: testing }
on_changes: { to: in-progress, comment: true }
items:
  - id: hero
    file: hero.png
    status: approved
    decided_by: sil
    decided_at: 2026-11-27T10:30:00Z
    comments: []
  - id: badge
    file: badge.png
    revises: badge-v1
    status: pending
    comments: []
---
YAML

# The check's page, bundled: no network is needed.
PAGE=$(python3 - <<'PY'
import base64
html = """<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>:root{color-scheme:light dark}body{font:17px -apple-system,sans-serif;margin:16px;background:#fff;color:#111}
@media (prefers-color-scheme: dark){body{background:#15171c;color:#eee}}button{font-size:22px;padding:14px 24px}</style>
</head><body><h1>Onboarding</h1><p id="w">Width</p><p id="s">Scheme</p>
<button id="b" onclick="this.textContent='Tapped'">Tap me</button>
<script>function u(){document.getElementById('w').textContent='Width '+innerWidth;
document.getElementById('s').textContent=matchMedia('(prefers-color-scheme: dark)').matches?'Scheme dark':'Scheme light'}
u();addEventListener('resize',u);matchMedia('(prefers-color-scheme: dark)').addEventListener('change',u)</script></body></html>"""
print("data:text/html;base64," + base64.b64encode(html.encode()).decode())
PY
)
cat > "$BOARD/review/PETS-3-page/review.md" <<YAML
---
config: review
id: PETS-3-page
card: PETS-3
title: Onboarding page check
question: Check the onboarding page on a phone and a desktop.
requested_by: claude
requested_at: 2026-11-27T11:00:00Z
for: [sil]
due: $YESTERDAY
on_accept: { to: testing }
on_changes: { to: in-progress, comment: true }
checks:
  - id: onboarding
    url: "$PAGE"
    title: Onboarding page
    note: The page prints the width it is laid out at.
    sizes: [phone, desktop]
    appearance: [light, dark]
    checklist:
      - { id: hero, text: The headline fits without an awkward break }
      - { id: cta, text: The button shows without scrolling }
    status: pending
    results: {}
    comments: []
---
YAML

cat > "$BOARD/review/PETS-4-copy/review.md" <<'YAML'
---
config: review
id: PETS-4-copy
card: PETS-4
title: Copy for the store
requested_by: claude
requested_at: 2026-11-27T12:00:00Z
for: [herma]
items:
  - id: copy
    file: copy.png
    status: pending
    comments: []
---
YAML

# Small plain-colour PNGs, so the files have something to show.
python3 - "$BOARD/review" <<'PY'
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
for path, rgb in [("PETS-1-site/hero.png", (240, 160, 60)), ("PETS-1-site/badge.png", (70, 160, 230)),
                  ("PETS-4-copy/copy.png", (150, 110, 70))]:
    png(f"{folder}/{path}", rgb)
PY

# The same JSON `AddedRepo` encodes to, stored as Data under the key AppModel reads.
python3 - "$PREFS" "$FIX" <<'PY'
import json, plistlib, sys
prefs, fixture = sys.argv[1], sys.argv[2]
repo = {"namespace": "folder", "name": "Review actions fixture", "branch": "", "isPrivate": True,
        "boards": [{"folder": "Tasks/Pets", "name": "Pets", "laneCount": 5, "memberCount": 3, "hasBacklog": False}],
        "kind": {"localFolder": {"path": fixture}}}
with open(prefs, "wb") as handle:
    plistlib.dump({"gitkanban.addedReposV2": json.dumps([repo]).encode(),
                   "gitkanban.storageMigratedToGroup": True}, handle)
PY
echo "$FIX"
