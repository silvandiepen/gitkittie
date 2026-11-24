#!/usr/bin/env bash
# A real IMAP/SMTP server on this machine for the GitKittieMailKit integration tests
# (Tests/MailIntegrationTests) and the gkmail-spike: GreenMail, standalone, loopback only.
#
#   scripts/test-mail-server.sh start    download (once, checksum-pinned), make a test CA, start
#   scripts/test-mail-server.sh stop
#   scripts/test-mail-server.sh status
#   scripts/test-mail-server.sh clean    stop and delete everything this script created
#
# Ports (127.0.0.1 only): IMAP 3143, IMAPS 3993, SMTP 3025, SMTPS 3465, admin API 3080.
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

# Seconds to wait for each port. A cold CI runner can need longer than a warm Mac
# (GKM_TEST_MAIL_SERVER_START_TIMEOUT, default 30).
START_TIMEOUT="${GKM_TEST_MAIL_SERVER_START_TIMEOUT:-30}"

wait_for_port() {
  local port=$1
  for _ in $(seq 1 $(( START_TIMEOUT * 2 ))); do
    nc -z 127.0.0.1 "$port" 2>/dev/null && return 0
    is_running || { tail -20 "$LOG_FILE" >&2; die "GreenMail exited during startup"; }
    sleep 0.5
  done
  # Say why: GreenMail's own log, and whether something else already holds the port.
  echo "--- start-up and API lines of $LOG_FILE ---" >&2
  grep -iE "api|rest|jetty|jersey|undertow|bind|address|started|starting|error|severe" "$LOG_FILE" | grep -v "SSL peer shut down" | head -40 >&2 || true
  echo "--- last lines of $LOG_FILE ---" >&2; tail -15 "$LOG_FILE" >&2 || true
  echo "--- listeners on port $port ---" >&2; lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
  die "port $port did not open within ${START_TIMEOUT} s (log: $LOG_FILE)"
}

start() {
  mkdir -p "$STATE_DIR"
  if is_running; then echo "Already running (pid $(cat "$PID_FILE"))."; return; fi
  for port in 3025 3465 3143 3993 3080; do
    nc -z 127.0.0.1 "$port" 2>/dev/null && die "port $port is already in use by another process"
  done
  local java
  java="$(find_java)"
  fetch_jar
  make_tls
  local local_part="${DEFAULT_USER%@*}"
  nohup "$java" \
    -Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.smtps \
    -Dgreenmail.setup.test.imap -Dgreenmail.setup.test.imaps \
    -Dgreenmail.setup.test.api -Dgreenmail.api.port=3080 \
    -Dgreenmail.hostname=127.0.0.1 \
    -Dgreenmail.users.login=email \
    -Dgreenmail.users="${local_part}:${DEFAULT_PASSWORD}@${DEFAULT_USER#*@}" \
    -Dgreenmail.tls.keystore.file="$TLS_DIR/server.p12" \
    -Dgreenmail.tls.keystore.password="$KEYSTORE_PASSWORD" \
    -jar "$JAR" >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  for port in 3025 3465 3143 3993 3080; do wait_for_port "$port"; done
  echo "GreenMail ${GREENMAIL_VERSION} running (pid $(cat "$PID_FILE"))."
  echo "  IMAPS localhost:3993, SMTPS localhost:3465, IMAP :3143, SMTP :3025, API :3080"
  echo "  CA: $TLS_DIR/ca.pem   user: $DEFAULT_USER / $DEFAULT_PASSWORD"
}

stop() {
  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"
    kill "$pid"
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
    echo "Stopped."
  else
    echo "Not running."
  fi
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
