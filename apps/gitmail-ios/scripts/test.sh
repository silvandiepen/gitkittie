#!/usr/bin/env zsh
# Builds GitKittie Mail for iPhone and iPad and runs its tests on a simulator: the app model and
# lifecycle tests (hosted in the app, so the Keychain has its entitlement) and the UI flow.
# Tests that need the local test mail server skip without it, unless GKM_REQUIRE_TEST_MAIL_SERVER=1:
#   swift/GitKittieMailProviders/scripts/test-mail-server.sh start
#
#   DESTINATION   default: the iPhone 17 Pro Max simulator
#   DERIVED_DATA_PATH, RESULT_BUNDLE (an .xcresult path; its screenshots go to SCREENSHOTS)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$ROOT_DIR/apps/gitmail-ios"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/gitmail-ios-derived-data}"
RESULT_BUNDLE="${RESULT_BUNDLE:-${TMPDIR:-/tmp}/gitmail-ios-tests.xcresult}"
SCREENSHOTS="${SCREENSHOTS:-}"

cd "$APP_DIR"
xcodegen generate --quiet
rm -rf "$RESULT_BUNDLE"

# TEST_RUNNER_ variables reach the test processes in the simulator without the prefix.
# Keep going after a failing test: the screenshots and the failure reasons matter most then.
test_status=0
TEST_RUNNER_GKM_REQUIRE_TEST_MAIL_SERVER="${GKM_REQUIRE_TEST_MAIL_SERVER:-}" \
xcodebuild test \
  -quiet \
  -project GitMail.xcodeproj \
  -scheme GitMail \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE" || test_status=$?

if [[ -d "$RESULT_BUNDLE" ]]; then
  if [[ -n "$SCREENSHOTS" ]]; then
    mkdir -p "$SCREENSHOTS"
    xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$SCREENSHOTS" || true
  fi
  if (( test_status != 0 )); then
    echo "--- why tests failed ---"
    xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" 2>/dev/null \
      | python3 -c '
import json, sys
def walk(node, path):
    name = node.get("name", "")
    if node.get("nodeType") == "Failure Message":
        print(f"{path}: {name}")
    for child in node.get("children", []):
        walk(child, f"{path} > {name}" if name else path)
data = json.load(sys.stdin)
for root in data.get("testNodes", []):
    walk(root, "")
' || true
  fi
fi
exit $test_status
