#!/usr/bin/env bash
# A real IMAP/SMTP server on this machine for the GitKittieMailKit integration tests
# (Tests/MailIntegrationTests) and the gkmail-spike: GreenMail, standalone, loopback only.
#
#   scripts/test-mail-server.sh start    download (once, checksum-pinned), make a test CA, start
#   scripts/test-mail-server.sh stop
#   scripts/test-mail-server.sh status
#   scripts/test-mail-server.sh clean    stop and delete everything this script created
#
# Ports (127.0.0.1 only): IMAP 3143, IMAPS 3993, SMTP 3025, SMTPS 3465, admin API 3080
# (GKM_TEST_MAIL_SERVER_{IMAP,IMAPS,SMTP,SMTPS,API}_PORT override them; the tests use the defaults).
# Ready means the admin API answers, which GreenMail starts only after every mail service is up.
# TLS uses a throwaway CA made here (valid 30 days, renewed on start); the tests trust only that
# CA, with full host name checks for "localhost". Nothing is added to the system keychain.
# All accounts are synthetic (example.com); the passwords below are not secrets.
#
# Needs Java 11+ (JAVA_HOME, /usr/libexec/java_home, Homebrew openjdk, or java on PATH) and
# openssl. State lives in $GKM_TEST_MAIL_SERVER_DIR (default ~/Library/Caches/GitKittieMail/
# test-mail-server), never in the repository.
set -euo pipefail

GREENMAIL_VERSION="2.1.3"
GREENMAIL_SHA256="9457fdaf45ded6c87bf84a321a5ced4b4b5e72b1d03686b778df381378afc4c8"
GREENMAIL_URL="https://repo1.maven.org/maven2/com/icegreen/greenmail-standalone/${GREENMAIL_VERSION}/greenmail-standalone-${GREENMAIL_VERSION}.jar"

STATE_DIR="${GKM_TEST_MAIL_SERVER_DIR:-$HOME/Library/Caches/GitKittieMail/test-mail-server}"
JAR="$STATE_DIR/greenmail-standalone-${GREENMAIL_VERSION}.jar"
PID_FILE="$STATE_DIR/greenmail.pid"
LOG_FILE="$STATE_DIR/greenmail.log"
TLS_DIR="$STATE_DIR/tls"
KEYSTORE_PASSWORD="gkm-test-keystore"

# Ports, overridable to run a second, separate server (with its own GKM_TEST_MAIL_SERVER_DIR).
# The tests expect the defaults.
SMTP_PORT="${GKM_TEST_MAIL_SERVER_SMTP_PORT:-3025}"
SMTPS_PORT="${GKM_TEST_MAIL_SERVER_SMTPS_PORT:-3465}"
IMAP_PORT="${GKM_TEST_MAIL_SERVER_IMAP_PORT:-3143}"
IMAPS_PORT="${GKM_TEST_MAIL_SERVER_IMAPS_PORT:-3993}"
API_PORT="${GKM_TEST_MAIL_SERVER_API_PORT:-3080}"
ALL_PORTS=("$SMTP_PORT" "$SMTPS_PORT" "$IMAP_PORT" "$IMAPS_PORT" "$API_PORT")

# The default synthetic account. Integration tests create their own per-test users via the API.
DEFAULT_USER="spike@example.com"
DEFAULT_PASSWORD="gkm-local-test-password"

die() { echo "test-mail-server: $*" >&2; exit 1; }

find_java() {
  local candidates=()
  [[ -n "${JAVA_HOME:-}" ]] && candidates+=("$JAVA_HOME/bin/java")
  if home=$(/usr/libexec/java_home 2>/dev/null); then candidates+=("$home/bin/java"); fi
  candidates+=(/opt/homebrew/opt/openjdk@21/bin/java /opt/homebrew/opt/openjdk/bin/java
               /usr/local/opt/openjdk/bin/java "$(command -v java 2>/dev/null || true)")
  for java in "${candidates[@]}"; do
    [[ -n "$java" && -x "$java" ]] && "$java" -version >/dev/null 2>&1 && { echo "$java"; return; }
  done
  die "no working Java runtime found (install one, e.g. 'brew install openjdk@21', or set JAVA_HOME)"
}

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

fetch_jar() {
  if [[ -f "$JAR" ]] && [[ "$(shasum -a 256 "$JAR" | cut -d' ' -f1)" == "$GREENMAIL_SHA256" ]]; then return; fi
  echo "Downloading GreenMail ${GREENMAIL_VERSION}…"
  curl -fsSL --retry 2 -o "$JAR.part" "$GREENMAIL_URL"
  local actual
  actual="$(shasum -a 256 "$JAR.part" | cut -d' ' -f1)"
  if [[ "$actual" != "$GREENMAIL_SHA256" ]]; then
    rm -f "$JAR.part"
    die "checksum mismatch for the GreenMail jar (got $actual)"
  fi
  mv "$JAR.part" "$JAR"
}

make_tls() {
  mkdir -p "$TLS_DIR"
  if [[ -f "$TLS_DIR/server.p12" && -f "$TLS_DIR/ca.pem" ]] \
     && openssl x509 -checkend 172800 -noout -in "$TLS_DIR/server.pem" >/dev/null 2>&1; then
    return
  fi
  echo "Creating a throwaway test CA and a certificate for localhost…"
  (
    cd "$TLS_DIR"
    rm -f ./*.pem ./*.key ./*.csr ./*.p12 ./*.srl ./*.cnf
    openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 30 \
      -subj "/CN=GitKittie Mail Test CA (local, throwaway)" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n' > server.cnf
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 29 \
      -extfile server.cnf 2>/dev/null
    openssl pkcs12 -export -inkey server.key -in server.pem -certfile ca.pem -name greenmail \
      -out server.p12 -passout "pass:$KEYSTORE_PASSWORD"
    rm -f ca.key server.csr ca.srl
  )
}

# Seconds one start attempt may take, for GreenMail's own per-service start-up wait and for the
# admin API to answer. A cold CI runner can need far longer than a warm Mac
# (GKM_TEST_MAIL_SERVER_START_TIMEOUT, default 30). A failed attempt is retried once.
START_TIMEOUT="${GKM_TEST_MAIL_SERVER_START_TIMEOUT:-30}"
START_ATTEMPTS=2

# GreenMail starts every mail service, waits for each one's socket with its own start-up timeout
# (2 s by default), and only then starts the admin API. A service that misses the 2 s (TLS set-up
# on a busy runner) makes the main thread throw, while the service threads keep the JVM alive:
# the mail ports open and the API never does. Hence the explicit greenmail.startup.timeout, the
# API as the only readiness signal, and the main-thread check below.
api_ready() {
  curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$API_PORT/api/service/readiness" 2>/dev/null
}

# GreenMail's start failed but the JVM lives on (see above): the failure is in the log.
start_failed_in_log() {
  grep -qE 'Exception in thread "main"|Can not open server socket' "$LOG_FILE" 2>/dev/null
}

# The lines that say why a start failed, then where the full log is.
explain_failure() {
  local log=$1
  echo "--- why GreenMail did not start ($log) ---" >&2
  if grep -qE 'Exception in thread "main"|Can not open server socket|BindException|Address already in use|SEVERE|ERROR' "$log" 2>/dev/null; then
    grep -E -A3 'Exception in thread "main"|Can not open server socket|BindException|Address already in use|SEVERE|ERROR' "$log" | head -30 >&2 || true
  else
    echo "(no error in the log; GreenMail was still starting)" >&2
    tail -10 "$log" >&2 || true
  fi
  echo "--- other listeners on the test ports (none is fine) ---" >&2
  for port in "${ALL_PORTS[@]}"; do lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 >&2 || true; done
}

kill_server() {
  [[ -f "$PID_FILE" ]] || return 0
  local pid
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$PID_FILE"
}

# One attempt: launch the JVM, wait for the API. Returns 1 with $FAIL_REASON set.
start_attempt() {
  local java=$1
  local local_part="${DEFAULT_USER%@*}"
  nohup "$java" \
    -Dgreenmail.hostname=127.0.0.1 \
    -Dgreenmail.smtp.port="$SMTP_PORT" -Dgreenmail.smtps.port="$SMTPS_PORT" \
    -Dgreenmail.imap.port="$IMAP_PORT" -Dgreenmail.imaps.port="$IMAPS_PORT" \
    -Dgreenmail.api.port="$API_PORT" \
    -Dgreenmail.startup.timeout="$(( START_TIMEOUT * 1000 ))" \
    -Dgreenmail.users.login=email \
    -Dgreenmail.users="${local_part}:${DEFAULT_PASSWORD}@${DEFAULT_USER#*@}" \
    -Dgreenmail.tls.keystore.file="$TLS_DIR/server.p12" \
    -Dgreenmail.tls.keystore.password="$KEYSTORE_PASSWORD" \
    -jar "$JAR" >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  local deadline=$(( SECONDS + START_TIMEOUT ))
  while (( SECONDS < deadline )); do
    api_ready && return 0
    if ! is_running; then FAIL_REASON="GreenMail exited during start-up"; return 1; fi
    if start_failed_in_log; then FAIL_REASON="GreenMail could not start its mail services"; return 1; fi
    sleep 0.5
  done
  api_ready && return 0
  FAIL_REASON="the admin API on port $API_PORT did not answer within ${START_TIMEOUT} s"
  return 1
}

start() {
  mkdir -p "$STATE_DIR"
  if is_running; then echo "Already running (pid $(cat "$PID_FILE"))."; return; fi
  for port in "${ALL_PORTS[@]}"; do
    nc -z 127.0.0.1 "$port" 2>/dev/null && die "port $port is already in use by another process"
  done
  local java
  java="$(find_java)"
  fetch_jar
  make_tls
  rm -f "$STATE_DIR"/greenmail.attempt-*.log
  local attempt
  for attempt in $(seq 1 "$START_ATTEMPTS"); do
    if start_attempt "$java"; then
      echo "GreenMail ${GREENMAIL_VERSION} running (pid $(cat "$PID_FILE"))."
      echo "  IMAPS localhost:$IMAPS_PORT, SMTPS localhost:$SMTPS_PORT, IMAP :$IMAP_PORT, SMTP :$SMTP_PORT, API :$API_PORT"
      echo "  CA: $TLS_DIR/ca.pem   user: $DEFAULT_USER / $DEFAULT_PASSWORD"
      (( attempt > 1 )) && echo "  (attempt $attempt; the failed attempt's log: $STATE_DIR/greenmail.attempt-1.log)"
      return 0
    fi
    kill_server
    cp "$LOG_FILE" "$STATE_DIR/greenmail.attempt-$attempt.log"
    echo "test-mail-server: attempt $attempt of $START_ATTEMPTS failed: $FAIL_REASON" >&2
    explain_failure "$STATE_DIR/greenmail.attempt-$attempt.log"
    (( attempt < START_ATTEMPTS )) && echo "test-mail-server: restarting the JVM…" >&2
  done
  die "GreenMail did not start: $FAIL_REASON (logs: $STATE_DIR/greenmail.attempt-*.log)"
}

stop() {
  if is_running; then kill_server; echo "Stopped."; else echo "Not running."; fi
  rm -f "$PID_FILE"
}

status() {
  if is_running; then echo "running (pid $(cat "$PID_FILE")), state in $STATE_DIR"; else echo "not running"; exit 1; fi
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  clean) stop; rm -rf "$STATE_DIR"; echo "Removed $STATE_DIR." ;;
  *) echo "usage: $0 start|stop|status|clean" >&2; exit 2 ;;
esac
