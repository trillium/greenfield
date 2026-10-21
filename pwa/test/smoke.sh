#!/usr/bin/env bash
# Browser smoke test: the real web app in a real Chrome (chrome-devtools-axi), through the page's server, against the real Windows
# helper built here and run with --dry-run (it accepts text and types nothing). Walks the whole path a tester takes: open, type a
# line break, see the Enter marker, pair with a one-time code, send, and check that the helper's log holds no code and no token.
# Needs: chrome-devtools-axi, Go, Node. Ports are picked free, state lives in a temporary directory, nothing is left running.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
command -v chrome-devtools-axi >/dev/null || { echo "smoke: chrome-devtools-axi is not installed" >&2; exit 2; }

tmp="$(mktemp -d)"
export GREENFIELD_INSERTER_HOME="$tmp/home"
export CHROME_DEVTOOLS_AXI_SESSION="greenfield-pwa-smoke"
pids=()
cleanup() {
  chrome-devtools-axi stop >/dev/null 2>&1 || true
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

free_port() { node -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})"; }
helper_port="$(free_port)"
pwa_port="$(free_port)"
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "- $*"; }
js() { # the value of a JavaScript expression in the page, as plain text
  chrome-devtools-axi eval "$1" 2>&1 | sed -n 's/^result: //p' | node -e '
    let v = require("fs").readFileSync(0, "utf8").trim();
    try { v = JSON.parse(v); v = JSON.parse(v); } catch {}
    process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));'
}
expect() { # expect "<description>" "<actual>" "<expected substring>"
  case "$2" in *"$3"*) step "$1: ok" ;; *) fail "$1: wanted \"$3\", got \"$2\"" ;; esac
}

step "build and start the helper (dry run, loopback only) on $helper_port"
(cd windows && go build -o "$tmp/helper" ./cmd/greenfield-inserter)
"$tmp/helper" serve --port "$helper_port" --bind 127.0.0.1 --dry-run --no-bonjour >"$tmp/helper.out" 2>&1 &
pids+=($!)
step "start the web app server on $pwa_port"
GREENFIELD_PWA_PORT="$pwa_port" GREENFIELD_PORT="$helper_port" node pwa/server.mjs >"$tmp/pwa.out" 2>&1 &
pids+=($!)
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$pwa_port/computers.json" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$pwa_port/computers.json" >/dev/null || fail "the web app server did not start: $(cat "$tmp/pwa.out")"

step "open the app"
chrome-devtools-axi open "http://localhost:$pwa_port/" >/dev/null 2>&1 || fail "could not open the page"
chrome-devtools-axi resize 390 844 >/dev/null 2>&1 || true
for _ in $(seq 1 30); do [ "$(js "() => document.body.dataset.ready || ''")" = "true" ] && break; sleep 0.3; done
expect "the page is ready" "$(js "() => document.body.dataset.ready")" "true"
expect "three screens, named as the phone app names them" "$(js "() => [...document.querySelectorAll('.tab')].map(t => t.textContent.trim()).join(',')")" "Dictate,Computers"
expect "Help is there" "$(js "() => document.getElementById('tab-help').textContent")" "Help"
expect "no computer is paired yet" "$(js "() => document.getElementById('ready-line').textContent")" "Pair a computer"

step "type text with a line break: the Enter marker shows, and the text itself has none"
chrome-devtools-axi eval "() => { const t = document.getElementById('text'); t.value = 'Hello there\nsecond line'; t.dispatchEvent(new Event('input')); }" >/dev/null 2>&1
expect "the marker is drawn at the line break" "$(js "() => document.getElementById('mirror').textContent")" $'Hello there↵'
expect "the box holds a plain line feed" "$(js "() => document.getElementById('text').value")" $'Hello there\nsecond line'

step "the computer list comes from the page's server"
chrome-devtools-axi eval "() => { location.hash = '#computers'; }" >/dev/null 2>&1
expect "the computer is listed, not paired" "$(js "() => document.getElementById('computer-list').innerText")" "This computer"

step "submitting before pairing keeps the text and says what to do"
chrome-devtools-axi eval "() => { location.hash = '#dictate'; document.getElementById('submit').click(); }" >/dev/null 2>&1
sleep 0.5
expect "the box still holds the text" "$(js "() => document.getElementById('text').value")" "second line"

step "a wrong code is refused in plain words"
chrome-devtools-axi eval "() => { location.hash = '#computers'; [...document.querySelectorAll('#computer-list button')].find(b => b.textContent === 'Pair').click(); const i = document.getElementById('pair-code'); i.value = 'ZZZZ-ZZZZ'; i.dispatchEvent(new Event('input')); document.getElementById('pair-form').requestSubmit(); }" >/dev/null 2>&1
sleep 1
expect "refused" "$(js "() => document.getElementById('pair-note').textContent")" "wrong, already used or out of time"

step "pair with a real one-time code from the helper"
out="$("$tmp/helper" pair --port "$helper_port")"
code="$(printf '%s\n' "$out" | grep -Eo '[A-Z0-9]{4}-[A-Z0-9]{4}' | head -1)"
[ -n "$code" ] || fail "no code in: $out"
chrome-devtools-axi eval "() => { const i = document.getElementById('pair-code'); i.value = '$code'; i.dispatchEvent(new Event('input')); document.getElementById('pair-form').requestSubmit(); }" >/dev/null 2>&1
sleep 1.5
expect "paired and ready" "$(js "() => document.getElementById('computer-list').innerText")" "Ready"
expect "the helper lists the device" "$("$tmp/helper" pair --port "$helper_port" --list)" "(PWA)"

step "send the text to the paired computer"
chrome-devtools-axi eval "() => { location.hash = '#dictate'; document.getElementById('submit').click(); }" >/dev/null 2>&1
sleep 1
expect "sent" "$(js "() => document.getElementById('send-note').textContent")" "Sent to This computer"
expect "the box is emptied" "$(js "() => document.getElementById('text').value")" ""
expect "the helper took it from the web app, 23 characters with the line break" "$("$tmp/helper" logs --tail 20)" "source=greenfield-pwa sent chars=23"

step "no code and no token in the helper's log"
token="$(js "() => JSON.parse(localStorage.getItem('greenfield.paired')).local.token")"
[ "${#token}" -ge 40 ] || fail "no token was kept"
log="$("$tmp/helper" logs --tail 200)"
case "$log" in *"$token"*) fail "the token is in the helper's log" ;; esac
case "$log" in *"${code//-/}"*|*"$code"*) fail "the code is in the helper's log" ;; esac
step "neither is in the log: ok"

step "forget ends the pairing at the helper too"
chrome-devtools-axi eval "() => { location.hash = '#computers'; [...document.querySelectorAll('#computer-list button')].find(b => b.textContent === 'Forget').click(); }" >/dev/null 2>&1
sleep 1
expect "no devices are left at the helper" "$("$tmp/helper" pair --port "$helper_port" --list)" "no paired devices"
echo "PASS: web app smoke test"
