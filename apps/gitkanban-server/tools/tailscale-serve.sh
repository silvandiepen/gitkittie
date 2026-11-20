#!/usr/bin/env bash
# Exposes the local gitkanban-server to your tailnet (HTTPS, tailnet-only — never Funnel)
# and prints the resulting URL. tailscale serve injects Tailscale-User-Login/-Name headers.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--port <local port>]

Runs: tailscale serve --bg --https=443 http://127.0.0.1:<port>   (default port 4417)
then prints the https URL from 'tailscale status --json' and 'tailscale serve status'.
To undo: tailscale serve reset   (note: clears this node's whole serve config)
USAGE
}

PORT="4417"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

TAILSCALE="$(command -v tailscale || true)"
if [[ -z "$TAILSCALE" && -x /opt/homebrew/bin/tailscale ]]; then TAILSCALE=/opt/homebrew/bin/tailscale; fi
if [[ -z "$TAILSCALE" ]]; then echo "tailscale CLI not found." >&2; exit 1; fi

if ! curl -fsS "http://127.0.0.1:$PORT/api/health" > /dev/null; then
  echo "Warning: nothing answered on http://127.0.0.1:$PORT/api/health — is gitkanban-server running?" >&2
fi

"$TAILSCALE" serve --bg --https=443 "http://127.0.0.1:$PORT"

DNS_NAME="$("$TAILSCALE" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
echo
echo "GitKanban server URL: https://$DNS_NAME"
echo
"$TAILSCALE" serve status
