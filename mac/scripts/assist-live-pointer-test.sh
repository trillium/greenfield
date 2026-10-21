#!/usr/bin/env bash
# ============================================================================================================================
# DISABLED. LIVE POINTER INJECTION TEST. This script MOVES THE REAL CURSOR of the Mac it runs against.
#
# Live pointer injection is BLOCKED until the captain approves a safe test plan (architecture decision D7): a scratch Mac or a
# macOS virtual machine that nobody is working on. Until then this script refuses to do anything, and no test, harness or
# `make` target calls it. The plan it implements is in docs/assist-pointer.md ("Live test").
#
# To enable it, ALL of these must be true, on the scratch machine only:
#   1. the captain has approved the plan (record who and when in the commit that flips ENABLED);
#   2. ENABLED below is changed from 0 to 1 in that commit;
#   3. the file ~/.greenfield-scratch-mac exists on the machine (touch it there; never on a Mac with someone's work on it);
#   4. GREENFIELD_ASSIST_LIVE_POINTER=I-AM-ON-THE-SCRATCH-MAC is set in the environment of the run.
# ============================================================================================================================
set -euo pipefail

ENABLED=0

if [ "$ENABLED" != 1 ]; then
  echo "assist-live-pointer-test: DISABLED. Live pointer injection is blocked until the captain approves a safe test plan" >&2
  echo "(scratch Mac or macOS VM, decision D7). Nothing was started and no pointer event was sent." >&2
  exit 3
fi
[ -e "$HOME/.greenfield-scratch-mac" ] || { echo "refusing: $HOME/.greenfield-scratch-mac is missing, so this is not marked as a scratch Mac" >&2; exit 3; }
[ "${GREENFIELD_ASSIST_LIVE_POINTER:-}" = "I-AM-ON-THE-SCRATCH-MAC" ] || { echo "refusing: GREENFIELD_ASSIST_LIVE_POINTER is not set to the scratch-Mac phrase" >&2; exit 3; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${GREENFIELD_BIN:-$here/.build/release/greenfield-inserter}"
port="${GREENFIELD_PORT:-47999}"
home="$(mktemp -d)"
export GREENFIELD_INSERTER_HOME="$home"
pid=""
cleanup() { [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$home"; }
trap cleanup EXIT

# The daemon listens on loopback only for this test (no tailnet), with its own throwaway settings directory.
"$bin" assist on
"$bin" assist pointer on
"$bin" serve --bind 127.0.0.1 --port "$port" --no-bonjour --log-stderr &
pid=$!
sleep 2
echo "the pointer should now draw a small square (40 points) on this Mac; watch it"
python3 "$here/scripts/assist_tpt1_probe.py" --live --http "127.0.0.1:$port"
"$bin" assist off
echo "assist-live-pointer-test: finished; record what was seen in docs/assist-pointer.md"
