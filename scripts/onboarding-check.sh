#!/usr/bin/env bash
# Scores how easy Greenfield is to start with, by facts only. The objective of the unattended improvement loop.
#
#   scripts/onboarding-check.sh          every check, including the slow ones (a fresh-HOME Mac install, both test suites)
#   scripts/onboarding-check.sh --fast   only the checks that read files (a few seconds); use this between edits
#
# Prints one PASS/FAIL line per check and a last line "SCORE <points>/<max>". Exit 0 only when points == max.
# The target: a new person with a Mac and an iPhone reaches a confirmed text insert in minutes, with no key or
# address typed and no document read. Typing a key or an address is a defect: every connection is detected,
# discovered or scanned (docs/mac-contract.md, README).
#
# The one human act that cannot be scripted is the macOS Accessibility approval. The fresh-HOME check therefore
# accepts "Ready." OR "Not ready yet. Next step: ... Accessibility ..." (that single step and nothing before it).
#
# This script is the referee: the loop must not edit it. It never touches the installed daemon, the installed app,
# signing or keys; the fresh-HOME install uses a throwaway label, port, prefix and HOME and removes them afterwards.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

# Test counts at the start of the loop. Fewer tests or assertions means a test was weakened or removed.
MIN_PHONE_TESTS=222 MIN_MAC_TESTS=141 MIN_PHONE_ASSERTS=662 MIN_MAC_ASSERTS=474

POINTS=0
MAX=0
score() { # score NAME WEIGHT PASS(0|1) DETAIL
    MAX=$((MAX + $2))
    if [ "$3" = 1 ]; then POINTS=$((POINTS + $2)); echo "PASS [$2] $1"; else echo "FAIL [$2] $1: $4"; fi
}
count() { # count REGEX FILES... : matching lines across files
    local re="$1"
    shift
    cat "$@" 2>/dev/null | grep -cE "$re" || true
}
swift_strings() { # every quoted string literal in the given files, one per line
    cat "$@" 2>/dev/null | grep -oE '"([^"\\]|\\.)*"' || true
}

# ---- A. The Mac installs itself -----------------------------------------------------------------------------
INSTALL=mac/install.sh
a1=0
if [ -x "$INSTALL" ] && bash -n "$INSTALL" 2>/dev/null && "$INSTALL" --help >/dev/null 2>&1; then a1=1; fi
score "A1 mac/install.sh exists, is executable, parses and answers --help" 1 $a1 "missing or broken"

a2=0
if [ -f "$INSTALL" ] && [ "$(count '(^|[^a-z_])read +(-[a-z]+ +)*[A-Za-z_]+' "$INSTALL" mac/scripts/agent.sh)" = 0 ]; then a2=1; fi
score "A2 the installer never stops to ask the user to type" 1 $a2 "install.sh or agent.sh uses read"

REHEARSAL_UP=0 REHEARSAL_READY=0 REHEARSAL_NOTE="skipped (--fast)"
UNTOUCHED=0 UNTOUCHED_NOTE="skipped (--fast)"
installed_fingerprint() {
    local bin="$HOME/.local/share/greenfield-inserter/greenfield-inserter" plist="$HOME/Library/LaunchAgents/local.greenfield.inserter.plist"
    { shasum "$bin" "$plist" 2>&1; launchctl list 2>/dev/null | awk '$3 == "local.greenfield.inserter" {print "loaded", $3}'; }
}
rehearse() {
    command -v swift >/dev/null && [ "$(uname)" = Darwin ] || { REHEARSAL_NOTE="needs macOS with swift"; return; }
    local tmp label port out
    tmp="$(mktemp -d /tmp/greenfield-rehearsal.XXXXXX)" || return
    label="local.greenfield.rehearsal.$$"
    port=$((48000 + RANDOM % 1000))
    mkdir -p "$tmp/home"
    if ! { (cd mac && scripts/stamp-version.sh >/dev/null 2>&1; swift build -c release >"$tmp/build.log" 2>&1) &&
        cp mac/.build/release/greenfield-inserter "$tmp/gi" && codesign --force --sign - --identifier greenfield-inserter "$tmp/gi" >/dev/null 2>&1; }; then
        REHEARSAL_NOTE="could not build the daemon (see $tmp/build.log)"
        return
    fi
    # A fresh HOME: nothing from this user's real setup is visible to the installer.
    if ! HOME="$tmp/home" GREENFIELD_INSERTER_HOME="$tmp/home/cfg" timeout 240 mac/install.sh --binary "$tmp/gi" --label "$label" --port "$port" \
        --prefix "$tmp/prefix" --home "$tmp/home/cfg" --no-setup --no-bonjour >"$tmp/install.log" 2>&1; then
        REHEARSAL_NOTE="install.sh failed: $(tail -2 "$tmp/install.log" | tr '\n' ' ')"
    else
        if curl -fsS --max-time 5 "http://127.0.0.1:$port/status" 2>/dev/null | grep -q '"ok" *: *true'; then REHEARSAL_UP=1; fi
        out="$(HOME="$tmp/home" GREENFIELD_INSERTER_HOME="$tmp/home/cfg" "$tmp/prefix/greenfield-inserter" ready --port "$port" --label "$label" \
            --install-to "$tmp/prefix/greenfield-inserter" 2>&1)"
        REHEARSAL_NOTE="ready said: $out"
        case "$out" in
        Ready.*) REHEARSAL_READY=1 ;;
        "Not ready yet. Next step: Switch on"*Accessibility*) REHEARSAL_READY=1 ;;
        esac
    fi
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
    rm -rf "$tmp"
}
if [ "$FAST" = 0 ]; then
    before="$(installed_fingerprint)"
    rehearse
    UNTOUCHED_NOTE="the installed daemon changed"
    [ "$(installed_fingerprint)" = "$before" ] && UNTOUCHED=1
fi
score "A3 a fresh-HOME install on a throwaway port starts a daemon that answers /status" 2 $REHEARSAL_UP "$REHEARSAL_NOTE"
score "A4 on that install 'greenfield-inserter ready' is green, or its one next step is the Accessibility approval" 2 $REHEARSAL_READY "$REHEARSAL_NOTE"
score "A5 the rehearsal left the installed daemon (binary, agent file, launchd job) exactly as it was" 1 $UNTOUCHED "${UNTOUCHED_NOTE}"

# ---- B. The phone app walks a new person through ------------------------------------------------------------
b1=0
if [ -f App/Sources/Flow/Onboarding.swift ] && [ -f App/Sources/Views/OnboardingView.swift ] &&
    grep -q 'onboarding.done' App/Sources/ContentView.swift && grep -q 'OnboardingView' App/Sources/ContentView.swift &&
    grep -q 'fullScreenCover' App/Sources/ContentView.swift; then b1=1; fi
score "B1 the first launch shows the checklist until it is done" 1 $b1 "ContentView does not present OnboardingView on first launch"

b2=0
if grep -q 'readyLine' App/Sources/Flow/OnboardingActions.swift && grep -rq 'Am I ready' App/Sources/Views; then b2=1; fi
score "B2 an 'Am I ready?' line is on screen" 1 $b2 "no Am I ready line in the views"

b3=0
tests="$(count 'func test' App/Tests/OnboardingTests.swift)"
if [ "$tests" -ge 12 ] && grep -q 'readyLine' App/Tests/OnboardingTests.swift && grep -q 'nextStep\|checklist' App/Tests/OnboardingTests.swift; then b3=1; fi
score "B3 the checklist and the ready line have at least 12 unit tests" 2 $b3 "only $tests tests in App/Tests/OnboardingTests.swift"

phone_tests="$(count 'func test' App/Tests/*.swift)"
mac_tests="$(count 'func test' mac/Tests/InserterCoreTests/*.swift)"
phone_asserts="$(count 'XCTAssert|XCTFail|XCTUnwrap' App/Tests/*.swift)"
mac_asserts="$(count 'XCTAssert|XCTFail|XCTUnwrap' mac/Tests/InserterCoreTests/*.swift)"
b4=0
if [ "$phone_tests" -ge "$MIN_PHONE_TESTS" ] && [ "$mac_tests" -ge "$MIN_MAC_TESTS" ] &&
    [ "$phone_asserts" -ge "$MIN_PHONE_ASSERTS" ] && [ "$mac_asserts" -ge "$MIN_MAC_ASSERTS" ]; then b4=1; fi
score "B4 no test or assertion was removed (phone $phone_tests/$phone_asserts, Mac $mac_tests/$mac_asserts)" 2 $b4 "fewer tests or assertions than at the start"

# ---- C. Nothing asks the user to type a key or an address ----------------------------------------------------
ADVANCED=App/Sources/Views/AdvancedComputerView.swift
outside="$(grep -rlE 'TextField|SecureField' App/Sources/Views | grep -vE 'AdvancedComputerView.swift|SoundsView.swift' || true)"
c1=0
[ -z "$outside" ] && [ -f "$ADVANCED" ] && c1=1
score "C1 the only typing fields for a computer live in $ADVANCED, outside the normal flow" 2 $c1 "text fields in: ${outside:-nothing; $ADVANCED is missing}"

flow_files="App/Sources/Flow/Onboarding.swift App/Sources/Flow/OnboardingActions.swift App/Sources/Views/OnboardingView.swift App/Sources/Views/TargetsView.swift App/Sources/Views/TargetPicker.swift App/Sources/Views/QRScannerView.swift App/Sources/Views/DictateView.swift App/Sources/Views/HealthView.swift"
# shellcheck disable=SC2086
offending="$(swift_strings $flow_files | grep -vF '\(' | grep -iE '\b(type|typing|typed|enter|paste|key|keys|address|addresses|hostname|tailnet name|ip)\b' | grep -viE 'no key|nothing to type|without typing|no typing|no address' | head -5 || true)"
score "C2 no user-facing line in the normal flow asks for a key, an address, a name or typing" 2 "$([ -z "$offending" ] && echo 1 || echo 0)" "$(echo "$offending" | tr '\n' ' ')"

# shellcheck disable=SC2086
nottyping="$(grep -nE 'case .*(typeKey|enterKey|enterAddress|typeAddress|paste)' App/Sources/Flow/Onboarding.swift || true)"
c3=0
[ -z "$nottyping" ] && [ "$(count 'findComputers' App/Sources/Flow/Onboarding.swift)" -gt 0 ] && c3=1
score "C3 no checklist fix is a typing action; finding computers is" 1 $c3 "$nottyping"

c4=0
if grep -qE 'func test.*(Single|Auto|Only).*(Choose|Select|Add)|func test.*(Choose|Select|Add).*(Single|Auto|Only)' App/Tests/OnboardingTests.swift App/Tests/*.swift 2>/dev/null; then c4=1; fi
score "C4 a test pins that one found computer is chosen without a tap" 1 $c4 "no auto-choose test"

c5=0
if grep -q 'greenfield' App/Resources/AppInfo.plist && grep -q 'handle(link' App/Sources/DictationApp.swift && [ -f App/Sources/Views/QRScannerView.swift ]; then c5=1; fi
score "C5 the phone opens greenfield://add links and has a QR scanner" 1 $c5 "URL scheme, onOpenURL or QR scanner missing"

# ---- D. Everything passes ------------------------------------------------------------------------------------
suites_note="skipped (--fast)"
mac_ok=0 phone_ok=0
if [ "$FAST" = 0 ]; then
    if make -C mac test >/tmp/greenfield-check-mac.log 2>&1; then mac_ok=1; else suites_note="make -C mac test failed (/tmp/greenfield-check-mac.log)"; fi
    # The simulator sometimes answers "Busy" to the first launch after a boot; that is not a test failure, so try once more.
    for _ in 1 2; do
        if make check >/tmp/greenfield-check-root.log 2>&1; then phone_ok=1; break; fi
        suites_note="make check failed (/tmp/greenfield-check-root.log)"
        grep -q 'failed preflight checks' /tmp/greenfield-check-root.log || break
        sleep 15
    done
fi
score "D1 make -C mac test passes" 1 $mac_ok "$suites_note"
score "D2 make check passes (shell, lint, secrets, version, stub receiver, phone tests)" 1 $phone_ok "$suites_note"

# ---- E. The document matches the runbook and the tools ------------------------------------------------------
DOC=docs/onboarding.md
score "E1 $DOC exists" 1 "$([ -f "$DOC" ] && echo 1 || echo 0)" "missing"
missing=""
for phrase in 'mac/install.sh' 'greenfield-inserter ready' 'Accessibility' 'Tailscale' 'same tailnet' 'microphone' 'local network' 'Speech model' \
    'Computers' 'Health' 'Can actually insert text' 'kitty-cmere' 'send it' 'greenfield-inserter doctor' 'selftest' 'MINOR' \
    'Update the Mac daemon' 'Update the app' 'locked'; do
    grep -qiF -- "$phrase" "$DOC" 2>/dev/null || missing="$missing [$phrase]"
done
score "E2 the document carries every step and every red-state fix of the runbook" 2 "$([ -z "$missing" ] && [ -f "$DOC" ] && echo 1 || echo 0)" "missing:$missing"

bad=""
if [ -f "$DOC" ]; then
    while read -r target; do
        grep -qE "^$target:" mac/Makefile || bad="$bad [make -C mac $target]"
    done < <(grep -oE 'make -C mac [a-z-]+' "$DOC" | awk '{print $4}' | sort -u)
    while read -r sub; do
        grep -qE "^  greenfield-inserter $sub( |$)|case \"$sub\"|\"$sub\"[,:]" mac/Sources/greenfield-inserter/main.swift || bad="$bad [greenfield-inserter $sub]"
    done < <(grep -oE 'greenfield-inserter [a-z]+' "$DOC" | awk '{print $2}' | sort -u)
    grep -qE 'make key|KEY=|show-key|macs add' "$DOC" && bad="$bad [asks for a key]"
fi
score "E3 every command in the document exists, and none asks for a key" 1 "$([ -f "$DOC" ] && [ -z "$bad" ] && echo 1 || echo 0)" "bad:$bad"

e4=0
if grep -q 'docs/onboarding.md' README.md && ! grep -qiE 'its own key|address and key|key under' README.md; then e4=1; fi
score "E4 the README points to the document and no longer tells people to add a key" 1 $e4 "README stale"

# ---- F. House rules ------------------------------------------------------------------------------------------
# The pattern is built from pieces so this file does not contain the words it forbids.
names="wis""pr|super""whisper|ta""lon|dra""gon|mac""whisper|aqua ""voice|voice""ink|wil""low voice|seren""ade|voice ""access|apple ""dictation"
others="$(git grep -liE "$names" -- . ':!scripts/onboarding-check.sh' 2>/dev/null | head -3 | tr '\n' ' ')"
score "F1 no other voice or input tool is named anywhere in the repo" 1 "$([ -z "$others" ] && echo 1 || echo 0)" "$others"

echo "SCORE $POINTS/$MAX"
[ "$POINTS" = "$MAX" ]
