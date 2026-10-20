#!/usr/bin/env bash
# Tests for version.sh against throwaway git repos. Run by `make check`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$tmp" init -q; mkdir -p "$tmp/Config"
export VERSION_REPO="$tmp"
fails=0
expect() { # expect LABEL WANT GOT
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fails=$((fails + 1)); fi
}
commit() { git -C "$tmp" commit -q --allow-empty -m "$1"; }

commit "feat: one"
expect "untagged marketing" "0.0.1" "$("$here/version.sh" --marketing)"
expect "untagged build" "1" "$("$here/version.sh" --build)"
git -C "$tmp" tag v0.2.0
expect "tagged marketing" "0.2.0" "$("$here/version.sh" --marketing)"
expect "tagged full" "0.2.0" "$("$here/version.sh" --full)"
commit "fix: two"; commit "fix: three"
expect "after tag marketing is next patch" "0.2.1" "$("$here/version.sh" --marketing)"
expect "build is commit count" "3" "$("$here/version.sh" --build)"
case "$("$here/version.sh" --full)" in 0.2.1+2.g*) echo "ok   full suffix";; *) echo "FAIL full suffix"; fails=$((fails + 1));; esac
expect "marketing has no suffix" "0.2.1" "$("$here/version.sh" --marketing)"
git -C "$tmp" tag v1.0.0
expect "major tag" "1.0.0" "$("$here/version.sh" --marketing)"
expect "xcconfig output" "MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 3" "$("$here/version.sh")"
"$here/version.sh" --write
if grep -q '^MARKETING_VERSION = 1.0.0$' "$tmp/Config/Version.xcconfig"; then echo "ok   write"; else echo "FAIL write"; fails=$((fails + 1)); fi
git -C "$tmp" tag v1.0.1-rc1 2>/dev/null; git -C "$tmp" tag -d v1.0.1-rc1 >/dev/null
expect "non-release tags ignored" "1.0.0" "$("$here/version.sh" --marketing)"
[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "version tests ok"
