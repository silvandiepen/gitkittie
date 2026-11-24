#!/usr/bin/env zsh
# Builds GitKittie Mail and runs its unit tests without launching the app: the test bundle
# carries the app model's sources and runs under xctest, not inside GitMail.app. The account
# tests use the local test mail server when it runs (swift/GitKittieMailProviders/scripts/
# test-mail-server.sh start) and skip otherwise.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/gitmail-macos-derived-data}"
PROJECT_PATH="$ROOT_DIR/apps/gitmail-macos/GitMail.xcodeproj"
TEST_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/GitMailTests.xctest"

xcodebuild build-for-testing \
  -quiet \
  -project "$PROJECT_PATH" \
  -scheme GitMail \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
env -i \
  HOME="$HOME" \
  TMPDIR="${TMPDIR:-/tmp}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:$DEVELOPER_DIR/usr/bin" \
  DEVELOPER_DIR="$DEVELOPER_DIR" \
  GKM_TEST_MAIL_SERVER_DIR="${GKM_TEST_MAIL_SERVER_DIR:-}" \
  GKM_REQUIRE_TEST_MAIL_SERVER="${GKM_REQUIRE_TEST_MAIL_SERVER:-}" \
  xcrun xctest "$TEST_BUNDLE"
