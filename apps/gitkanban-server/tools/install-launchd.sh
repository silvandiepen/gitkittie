#!/usr/bin/env bash
# Builds gitkanban-server and installs it as a per-user launchd agent that starts at login
# and is restarted if it exits. Re-running replaces the existing agent.
set -euo pipefail

LABEL="com.gitkittie.gitkanban-server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/gitkanban-server.log"

usage() {
  cat <<USAGE
Usage: $(basename "$0") <root> [--port <port>] [--host <host>] [--allowed-logins <a@x,b@y>]

  <root>              Absolute folder to serve (GKS_ROOT), e.g. /Users/you/Projects
  --port              GKS_PORT (default 4417)
  --host              GKS_HOST (default 127.0.0.1 — keep it on localhost; expose via tailscale serve)
  --allowed-logins    GKS_ALLOWED_LOGINS, comma-separated Tailscale logins
  --dry-run           Print the plist to stdout; don't build, write or load anything

Writes $PLIST,
logs to $LOG, and (re)loads it with launchctl bootout/bootstrap.
Uses the absolute path of the node binary currently on PATH (process.execPath).
USAGE
}

ROOT=""
PORT="4417"
HOST="127.0.0.1"
LOGINS=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --allowed-logins) LOGINS="${2:?--allowed-logins needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$ROOT" ]]; then echo "Only one <root> may be given." >&2; exit 2; fi
      ROOT="$1"; shift ;;
  esac
done

if [[ -z "$ROOT" ]]; then usage >&2; exit 2; fi
if [[ "$ROOT" != /* ]]; then echo "<root> must be an absolute path: $ROOT" >&2; exit 2; fi
if [[ ! -d "$ROOT" ]]; then echo "<root> is not a directory: $ROOT" >&2; exit 2; fi

if ! command -v node > /dev/null; then echo "node not found on PATH." >&2; exit 1; fi
# The real binary, not a version-manager shim: launchd runs without your shell's PATH.
NODE="$(node -p 'process.execPath')"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd -P)"

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}

LOGINS_ENTRY=""
if [[ -n "$LOGINS" ]]; then
  LOGINS_ENTRY="    <key>GKS_ALLOWED_LOGINS</key><string>$(xml_escape "$LOGINS")</string>"
fi

render_plist() {
  cat <<PLISTXML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$NODE")</string>
    <string>$(xml_escape "$APP_DIR/dist/index.js")</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$APP_DIR")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>GKS_ROOT</key><string>$(xml_escape "$ROOT")</string>
    <key>GKS_PORT</key><string>$(xml_escape "$PORT")</string>
    <key>GKS_HOST</key><string>$(xml_escape "$HOST")</string>
$LOGINS_ENTRY
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG")</string>
</dict>
</plist>
PLISTXML
}

if [[ "$DRY_RUN" == 1 ]]; then
  render_plist
  exit 0
fi

echo "Building @gitkittie/gitkanban-server…"
(cd "$REPO_DIR" && npm run build -w @gitkittie/gitkanban-server)

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
render_plist > "$PLIST"
plutil -lint "$PLIST"

DOMAIN="gui/$(id -u)"
if launchctl print "$DOMAIN/$LABEL" > /dev/null 2>&1; then
  echo "Unloading existing $LABEL…"
  launchctl bootout "$DOMAIN/$LABEL"
fi
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed $LABEL serving $ROOT on http://$HOST:$PORT"
echo "Logs: $LOG"
echo "Check: curl -s http://$HOST:$PORT/api/health"
