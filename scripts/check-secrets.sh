#!/usr/bin/env bash
# Block signing material and credentials from entering git.
# Rung: hook + make check (not an instruction). Canonical copy lives in the
# starter's template/scripts/; new-app copies it into every stamped app.
#
# Usage: check-secrets.sh --staged     scan the git index (pre-commit)
#        check-secrets.sh --tracked    scan every tracked file (make check)
# Exit 1 on any finding. Only paths and rule names are printed, never contents.
set -euo pipefail

mode="${1:---tracked}"
case "$mode" in
  --staged) list() { git diff --cached --name-only --diff-filter=ACMR; }
            body() { git show ":$1"; } ;;
  --tracked) list() { git ls-files; }
             body() { cat -- "$1"; } ;;
  *) echo "usage: $0 [--staged|--tracked]" >&2; exit 2 ;;
esac

# Filename rules (matched against the basename, case-insensitive).
name_blocked() {
  local base lower
  base="$(basename "$1")"
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    .env.example) return 1 ;;
    *.p8|*.p12|*.pfx|*.mobileprovision|*.provisionprofile|*.certsigningrequest) return 0 ;;
    *.keychain|*.keychain-db|*.pem|*.key|authkey_*|.env|.env.*) return 0 ;;
  esac
  return 1
}

# Content rules, assembled from pieces so this file never matches itself.
dash="-----"
pat_key="${dash}BEGIN [A-Z ]*PRIVATE KEY${dash}"
pat_jwt='eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}\.'

fail=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if name_blocked "$path"; then
    echo "BLOCKED (filename): $path"
    fail=1
    continue
  fi
  [ "$mode" = "--staged" ] || [ -f "$path" ] || continue
  if body "$path" 2>/dev/null | grep -aEq -e "$pat_key"; then
    echo "BLOCKED (private key block): $path"
    fail=1
  elif body "$path" 2>/dev/null | grep -aEq -e "$pat_jwt"; then
    echo "BLOCKED (JWT-shaped token): $path"
    fail=1
  fi
done < <(list)

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'MSG'
error: signing material or credentials must never be committed.
  Keep keys outside the repo (see docs/signing.md); reference them by env var path.
  If a file is a false positive, rename it or fix the rule here -- do not bypass the hook.
MSG
  exit 1
fi
echo "secrets: ok ($mode)"
