#!/bin/bash
# Runs the installed DictationSpike app once per engine and pass, headless, and collects the SPIKE-RESULT JSON lines.
# Each engine runs in its own process so one model's memory never inflates the next. Pass "cold" is the first launch (downloads and
# compiles the model); pass "warm" is a second launch with the compiled cache in place.
# Usage: tools/spike/run_on_device.sh [--passes "cold warm"] [--loop N] ENGINE [ENGINE ...]
# Env: DEVICE (devicectl identifier; default: the first connected device), OUT (default build/spike-results), TIMEOUT (seconds per run, default 1500).
# Needs the app installed first (signing needs the desktop keychain; see docs/spike-dictation.md).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
passes="cold warm"; loop=0
while [ $# -gt 0 ]; do
  case "$1" in
    --passes) passes="$2"; shift 2 ;;
    --loop) loop="$2"; shift 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: $0 [--passes \"cold warm\"] [--loop N] ENGINE..." >&2; exit 2; }
OUT="${OUT:-$root/build/spike-results}"; mkdir -p "$OUT"
TIMEOUT="${TIMEOUT:-1500}"
BUNDLE="$(grep -E '^PRODUCT_BUNDLE_IDENTIFIER' "$root/Config/Base.xcconfig" | sed -E 's/^[^=]*=[[:space:]]*//').spike"
if [ -z "${DEVICE:-}" ]; then
  json="$(mktemp)"; xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
  DEVICE="$(/usr/bin/python3 -c "
import json,sys
d=json.load(open('$json'))['result']['devices']
c=[x for x in d if x.get('connectionProperties',{}).get('tunnelState')=='connected' or x.get('connectionProperties',{}).get('transportType')]
print((c or d)[0]['identifier'])")"
  rm -f "$json"
fi
for engine in "$@"; do
  for pass in $passes; do
    log="$OUT/$engine-$pass.log"
    echo "== $engine ($pass) on $DEVICE"
    # shellcheck disable=SC2086
    timeout "$TIMEOUT" xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console "$BUNDLE" -- \
      -spike-engine "$engine" -spike-tag "$pass" -spike-loop "$loop" -spike-exit YES >"$log" 2>&1 || echo "run ended with status $? (see $log)"
    grep -h '^SPIKE-RESULT ' "$log" | sed 's/^SPIKE-RESULT //' >>"$OUT/results.jsonl" || echo "no result line for $engine ($pass)"
    grep -h '^SPIKE ' "$log" | tail -3
  done
done
echo "results appended to $OUT/results.jsonl"
