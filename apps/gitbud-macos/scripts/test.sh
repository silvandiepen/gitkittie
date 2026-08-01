#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DERIVED_DATA_PATH="${TMPDIR:-/tmp}/gitbud-macos-derived-data"
PROJECT_PATH="$ROOT_DIR/apps/gitbud-macos/GitBud.xcodeproj"
TEST_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/GitBudTests.xctest"

xcodebuild build-for-testing \
  -quiet \
  -project "$PROJECT_PATH" \
  -scheme GitBud \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO

env -i \
  HOME="$HOME" \
  TMPDIR="${TMPDIR:-/tmp}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin" \
  DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcrun xctest "$TEST_BUNDLE"
