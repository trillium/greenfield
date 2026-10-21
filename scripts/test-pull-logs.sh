#!/usr/bin/env bash
# Tests for scripts/pull-logs.sh: redaction of every kind of source, the since/tail limits, private output outside any repository,
# and that each source kind asks for exactly what it should (a stubbed devicectl, ssh and daemon; nothing real is touched).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/pull-logs.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/test-pull-logs.XXXXXX")"
server_pid=""
cleanup() { [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }
check() { # check DESCRIPTION CONDITION-COMMAND...
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$what"; fi
}
absent() { ! grep -rqF -- "$1" "${@:2}"; }

# Secrets built at run time so no scanner mistakes a canary for a credential.
canary="canary-$(printf '7f3a9c%.0s' 1 2 3 4 5 6 7)"
password="hunter$((1 + 1))"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

fixture="$work/fixture.log"
{
  echo "# support log, format 1"
  echo "$old old line that is outside the window"
  echo "$now sent chars=41 id=6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E"
  echo "$now header X-Example-Key: $canary"
  echo "$now got Authorization: Bearer $canary and token=$canary"
  echo "$now url http://user:$password@host/path and password=$password"
  echo "$now hash $(printf 'ab%.0s' $(seq 1 40))"
  echo "continuation without a time $canary"
} >"$fixture"

conf="$work/logs.conf"
bin="$work/bin"; mkdir -p "$bin"
cat >"$conf" <<CONF
LOGS_TARGETS="phone daemon filed remote"
LOGS_DEFAULT_OUT="$work/default-out"
LOGS_T_phone="device|iPhone|Library/Application Support/support-log.txt"
LOGS_T_daemon="daemon|127.0.0.1|PORT"
LOGS_T_filed="file|$fixture"
LOGS_T_remote="ssh|somehost|~/.app/app.log|receiver"
CONF

run() { LOGS_CONF="$conf" PATH="$bin:$PATH" "$PULL" "$@"; }

# --- a file source: redacted, windowed, private ---------------------------------------------------------------------------------
out="$work/out1"
run --target filed --out "$out" >"$work/run1.txt" 2>&1; rc=$?
check "file source exits 0" test "$rc" -eq 0
check "no canary survives" absent "$canary" "$out"
check "no password survives" absent "$password" "$out"
check "no long opaque string survives" absent "$(printf 'ab%.0s' $(seq 1 40))" "$out"
check "ids survive" grep -q "6F1C2E0A-5B7D-4E8B-9C41-0A2D3B4C5D6E" "$out/filed.log"
check "the line outside the window is gone" absent "old line that is outside" "$out"
check "the header line stays" grep -q "^# support log" "$out/filed.log"
# shellcheck disable=SC2012  # the names are our own temp paths
mode_of() { ls -ld "$1" | cut -c1-10; }
check "the output folder is private" test "$(mode_of "$out")" = "drwx------"
check "the file is private" test "$(mode_of "$out/filed.log")" = "-rw-------"
check "tail limits the lines" bash -c "LOGS_CONF='$conf' '$PULL' --target filed --tail 2 --out '$work/out2' >/dev/null && [ \"\$(grep -vc '^#' '$work/out2/filed.log')\" -eq 2 ]"

# --- limits and refusals --------------------------------------------------------------------------------------------------------
check "refuses an output folder inside a repository" bash -c "! LOGS_CONF='$conf' '$PULL' --target filed --out '$ROOT/pull-logs-test-out' >/dev/null 2>&1 && [ ! -e '$ROOT/pull-logs-test-out' ]"
check "refuses an unknown target" bash -c "! LOGS_CONF='$conf' '$PULL' --target nonsense --out '$work/x' >/dev/null 2>&1"
check "refuses since over 7d" bash -c "! LOGS_CONF='$conf' '$PULL' --since 8d --out '$work/x' >/dev/null 2>&1"
check "refuses a bad since" bash -c "! LOGS_CONF='$conf' '$PULL' --since soon --out '$work/x' >/dev/null 2>&1"
check "refuses tail 0 and tail 2001" bash -c "! LOGS_CONF='$conf' '$PULL' --tail 0 --out '$work/x' >/dev/null 2>&1 && ! LOGS_CONF='$conf' '$PULL' --tail 2001 --out '$work/x' >/dev/null 2>&1"
check "lists its targets" bash -c "LOGS_CONF='$conf' '$PULL' --list | grep -qx phone"

# --- the daemon: asks GET /logs with the limits, fails closed on every refusal ------------------------------------------------------
cat >"$work/stub.py" <<'PY'
import http.server, sys
status, bodyfile, logfile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(logfile, "a").write(self.path + "\n")
        data = open(bodyfile, "rb").read()
        self.send_response(status); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
daemon_case() { # daemon_case STATUS BODYFILE -> sets $port, $requests
  [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null; server_pid=""; }
  requests="$work/requests.txt"; : >"$requests"
  python3 "$work/stub.py" "$1" "$2" "$requests" >"$work/port.txt" &
  server_pid=$!
  for _ in $(seq 1 50); do [ -s "$work/port.txt" ] && break; sleep 0.1; done
  port="$(cat "$work/port.txt")"
  sed -i.bak "s/^LOGS_T_daemon=.*/LOGS_T_daemon=\"daemon|127.0.0.1|$port\"/" "$conf"
}
daemon_case 200 "$fixture"
run --target daemon --since 2h --tail 50 --out "$work/out3" >"$work/run3.txt" 2>&1; rc=$?
check "daemon source exits 0" test "$rc" -eq 0
check "daemon asked for /logs with format, tail and since" grep -qx '/logs?format=text&tail=50&since=7200s' "$requests"
check "daemon output is redacted again here" absent "$canary" "$work/out3"
echo '{"ok":false,"error":"rate_limited","message":"too many log requests"}' >"$work/err.json"
for pair in 404:"predates" 401:"same tailnet user" 403:"tailnet user" 429:"rate limited" 503:"cannot verify"; do
  daemon_case "${pair%%:*}" "$work/err.json"
  run --target daemon --out "$work/out-${pair%%:*}" >"$work/run-${pair%%:*}.txt" 2>&1; rc=$?
  check "daemon ${pair%%:*} fails the run" test "$rc" -ne 0
  check "daemon ${pair%%:*} says what to do" grep -qi "${pair#*:}" "$work/run-${pair%%:*}.txt"
  check "daemon ${pair%%:*} writes no log file" test ! -e "$work/out-${pair%%:*}/daemon.log"
done
[ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null; server_pid=""; }
sed -i.bak "s/^LOGS_T_daemon=.*/LOGS_T_daemon=\"daemon|127.0.0.1|1\"/" "$conf"
run --target daemon --out "$work/out-down" >"$work/run-down.txt" 2>&1; rc=$?
check "an unreachable daemon fails the run" test "$rc" -ne 0
check "an unreachable daemon names the host" grep -q "127.0.0.1" "$work/run-down.txt"

# --- the phone: finds the device by name, copies one file, no hard-coded id -----------------------------------------------------------
cat >"$bin/xcrun" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
if [ "$2" = "list" ]; then
  echo "Name                Hostname                            Identifier                             State       Model"
  echo "trillium’s iPhone   phone.coredevice.local   AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB   connected   iPhone 17"
  echo "Some iPad           ipad.coredevice.local    CCCCCCCC-1111-2222-3333-DDDDDDDDDDDD   connected   iPad"
  exit 0
fi
case "${FAKE_MODE:-ok}" in
  locked) echo "error: the device is locked" >&2; exit 1 ;;
  missing) echo "error: file does not exist" >&2; exit 1 ;;
esac
dest=""; while [ $# -gt 0 ]; do [ "$1" = "--destination" ] && dest="$2"; shift; done
cp "$FAKE_FIXTURE" "$dest"
SH
chmod +x "$bin/xcrun"
export FAKE_LOG="$work/xcrun.log" FAKE_FIXTURE="$fixture"
: >"$FAKE_LOG"
run --target phone --out "$work/out4" >"$work/run4.txt" 2>&1; rc=$?
check "phone source exits 0" test "$rc" -eq 0
check "phone uses the id found by name" grep -q -- "--device AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB" "$FAKE_LOG"
check "phone copies from the app container" grep -q -- "--domain-type appDataContainer" "$FAKE_LOG"
check "phone copies only the support log" grep -q -- "--source Library/Application Support/support-log.txt" "$FAKE_LOG"
check "phone never copies the outbox or events files" bash -c "! grep -qE 'outbox|events.json' '$FAKE_LOG'"
check "phone output is redacted" absent "$canary" "$work/out4"
check "the script has no device id of its own" bash -c "! grep -qE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' '$PULL'"
for mode in locked:"locked" missing:"no support log"; do
  FAKE_MODE="${mode%%:*}" run --target phone --out "$work/out-${mode%%:*}" >"$work/run-${mode%%:*}.txt" 2>&1; rc=$?
  check "phone ${mode%%:*} fails the run" test "$rc" -ne 0
  check "phone ${mode%%:*} says what to do" grep -qi "${mode#*:}" "$work/run-${mode%%:*}.txt"
done
check "LOGS_DEVICE overrides the lookup" bash -c ": >'$FAKE_LOG'; LOGS_DEVICE=EEEEEEEE-0000-0000-0000-FFFFFFFFFFFF LOGS_CONF='$conf' PATH='$bin:$PATH' '$PULL' --target phone --out '$work/out5' >/dev/null && grep -q -- '--device EEEEEEEE' '$FAKE_LOG'"

# --- ssh: one read-only command, key auth only, only the lines asked for ------------------------------------------------------------
cat >"$bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_SSH"
echo "2026-10-20 10:00:00.1 TRACE stdio: receiver: metrics ok"
echo "2026-10-20 10:00:01.1 TRACE stdio: receiver: header X-Example-Key: $FAKE_SECRET"
SH
chmod +x "$bin/ssh"
export FAKE_SSH="$work/ssh.txt" FAKE_SECRET="$canary"
LOGS_CONF="$conf" PATH="$bin:$PATH" "$PULL" --target remote --since 7d --out "$work/out6" >"$work/run6.txt" 2>&1; rc=$?
check "ssh source exits 0" test "$rc" -eq 0
check "ssh never asks for a password" grep -q -- "-o BatchMode=yes" "$FAKE_SSH"
# shellcheck disable=SC2016  # the dollar sign is literal: the remote shell expands it
check "ssh runs one tail piped through a fixed-string grep" grep -q -- 'somehost tail -n 20000 "$HOME/.app/app.log" | grep -F -- .receiver.' "$FAKE_SSH"
check "ssh runs nothing that writes" bash -c "! grep -qE '>|rm |mv |tee|dd |sudo' '$FAKE_SSH'"
check "ssh output is redacted" absent "$canary" "$work/out6"
check "ssh output keeps the lines" grep -q "metrics ok" "$work/out6/remote.log"
sed -i.bak 's/receiver/x; rm -rf ~/' "$conf"
check "a shell character in the config is refused" bash -c "! LOGS_CONF='$conf' PATH='$bin:$PATH' '$PULL' --target remote --out '$work/out7' >/dev/null 2>&1"

echo "pull-logs tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
