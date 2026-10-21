#!/usr/bin/env bash
# Compare the shared files (scripts/parity-manifest.txt) with the sibling repo, byte for byte.
# Usage: check-parity.sh SIBLING_PATH [-v]
# Lists every file that differs or exists in only one repo, with a diff summary (-v adds the diff).
# Exit 0 when identical, 1 on drift, 2 on a usage error. See docs/parity.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sibling="${1:-}"; verbose="${2:-}"
[ -n "$sibling" ] || { echo "usage: check-parity.sh SIBLING_PATH [-v]   (make check-parity SIBLING=<path>)" >&2; exit 2; }
[ -d "$sibling" ] || { echo "check-parity: not a directory: $sibling" >&2; exit 2; }
sibling="$(cd "$sibling" && pwd)"
[ "$sibling" != "$root" ] || { echo "check-parity: SIBLING is this repo" >&2; exit 2; }

drift=0; n=0
while IFS= read -r path || [ -n "$path" ]; do
  case "$path" in ""|"#"*) continue ;; esac
  n=$((n + 1))
  a="$root/$path"; b="$sibling/$path"
  if [ ! -f "$a" ] && [ ! -f "$b" ]; then
    echo "MISSING  $path (in neither repo)"; drift=$((drift + 1))
  elif [ ! -f "$a" ]; then
    echo "ONLY-SIBLING  $path"; drift=$((drift + 1))
  elif [ ! -f "$b" ]; then
    echo "ONLY-HERE  $path"; drift=$((drift + 1))
  elif ! cmp -s "$a" "$b"; then
    added="$(diff "$a" "$b" | grep -c '^>' || true)"; removed="$(diff "$a" "$b" | grep -c '^<' || true)"
    echo "DRIFT  $path (sibling has +$added/-$removed lines against this repo)"
    [ "$verbose" != -v ] || diff -u "$a" "$b" | sed 's/^/    /' || true
    drift=$((drift + 1))
  fi
done < "$root/scripts/parity-manifest.txt"

if [ "$drift" -gt 0 ]; then
  echo "check-parity: $drift of $n shared file(s) differ from $sibling (docs/parity.md: change once, copy across)" >&2
  exit 1
fi
echo "check-parity: $n shared file(s) identical to $sibling"
