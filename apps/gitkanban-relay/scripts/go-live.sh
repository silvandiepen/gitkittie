#!/bin/zsh
# Turn on instant review notifications: put the relay's secrets in place, deploy it, and point
# the "GitKittie Tasks" GitHub App's webhook at it. For Sil to run, once, from this folder:
#
#   cd apps/gitkanban-relay && zsh scripts/go-live.sh
#
# What it changes: the gitkanban-relay Worker on Cloudflare (three secrets, a deploy with the
# GitHubRepo Durable Object migration), and the GitHub App's webhook URL. What it does not:
# the App's "Active" checkbox (GitHub has no API for it) and Apple's portal; it says when to
# do those. Secrets go from the Keychain / key file straight into `wrangler secret put` and
# are never printed. See docs/Push.md.

set -euo pipefail
cd "$(dirname "$0")/.."

RELAY_URL="${RELAY_URL:-https://gitkanban-relay.vandipyan.workers.dev}"
KEYCHAIN_ACCOUNT="gitkittie-tasks"
APNS_KEY_FILE="${APNS_KEY_FILE:-$HOME/Projects/Apple Distribution/Push/AuthKey_37WP9V9P6N.p8}"
APP_SETTINGS="https://github.com/settings/apps/gitkittie-tasks"

step() { print -P "\n%B==> $1%b"; }

# A Keychain item's secret on standard output. `security -w` prints an item that holds a line
# break (a PEM key) as hex; turn that back into the text.
keychain_secret() {
  local value
  value="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$1" -w)"
  if [[ "$value" =~ '^[0-9a-f]+$' && $(( ${#value} % 2 )) -eq 0 && "$1" == *private-key ]]; then
    print -rn -- "$value" | xxd -r -p
  else
    print -rn -- "$value"
  fi
}

step "Checking the tools"
npx wrangler whoami >/dev/null || { print "Log in first: npx wrangler login"; exit 1; }
[[ -f "$APNS_KEY_FILE" ]] || { print "No APNs key at $APNS_KEY_FILE (set APNS_KEY_FILE)"; exit 1; }
for service in gitkittie-tasks.github-app.private-key gitkittie-tasks.github-app.webhook-secret; do
  security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$service" >/dev/null 2>&1 \
    || { print "Keychain item $service (account $KEYCHAIN_ACCOUNT) is missing"; exit 1; }
done
keychain_secret gitkittie-tasks.github-app.private-key | grep -q "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY" \
  || { print "The GitHub App key in the Keychain is not a PEM key"; exit 1; }

step "Tests"
npm run typecheck
npm test

step "Secrets (from the Keychain and the APNs key file; not shown)"
keychain_secret gitkittie-tasks.github-app.private-key | npx wrangler secret put GITHUB_APP_PRIVATE_KEY
keychain_secret gitkittie-tasks.github-app.webhook-secret | npx wrangler secret put GITHUB_WEBHOOK_SECRET
npx wrangler secret put APNS_PRIVATE_KEY < "$APNS_KEY_FILE"

step "Deploy"
npx wrangler deploy
curl -fsS "$RELAY_URL/" >/dev/null && print "Relay answers at $RELAY_URL"

step "Point the GitHub App's webhook at the relay"
# Authenticate as the App: an RS256 JWT from its private key (read by node from stdin).
APP_JWT="$(keychain_secret gitkittie-tasks.github-app.private-key | node --input-type=module -e '
  import { createSign } from "node:crypto";
  let key = ""; for await (const chunk of process.stdin) key += chunk;
  const now = Math.floor(Date.now() / 1000);
  const part = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const input = `${part({ alg: "RS256", typ: "JWT" })}.${part({ iss: "5963429", iat: now - 60, exp: now + 540 })}`;
  const signature = createSign("RSA-SHA256").update(input).sign(key).toString("base64url");
  process.stdout.write(`${input}.${signature}`);
')"
curl -fsS -X PATCH "https://api.github.com/app/hook/config" \
  -H "Authorization: Bearer $APP_JWT" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "{\"url\":\"$RELAY_URL/github\",\"content_type\":\"json\",\"insecure_ssl\":\"0\"}" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s);console.log(`Webhook URL: ${c.url} (${c.content_type})`)})'
unset APP_JWT

step "Left to do by hand"
cat <<EOF
1. $APP_SETTINGS → Webhook: tick "Active" and Save (GitHub has no API for this).
   Then Advanced → Recent Deliveries should show a ping answered 200 by the relay.
2. Apple: the App ID app.hakobs.gitkanban needs Push Notifications and Time Sensitive
   Notifications. Automatic signing adds both on the next signed build of Tasks
   (Xcode, or ./fl build app:gitkanban in ~/Projects/_appstore, which changes the portal),
   or tick them at developer.apple.com → Identifiers → app.hakobs.gitkanban.
3. Install GitKittie Tasks on a board repo from Tasks → Notifications → Turn On, ask a review
   with notify: urgent, and watch it arrive (docs/Push.md → Check it works).
EOF
