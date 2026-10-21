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
sha="$(git -C "$tmp" rev-parse --short=7 HEAD)"
expect "xcconfig output" "MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 3
GIT_COMMIT = $sha" "$("$here/version.sh")"
expect "commit" "$sha" "$("$here/version.sh" --commit)"
expect "newest tag" "v1.0.0" "$("$here/version.sh" --tag)"
"$here/version.sh" --write
if grep -q '^MARKETING_VERSION = 1.0.0$' "$tmp/Config/Version.xcconfig"; then echo "ok   write"; else echo "FAIL write"; fails=$((fails + 1)); fi
touch -t 200001010000 "$tmp/Config/Version.xcconfig"; "$here/version.sh" --write
expect "write leaves an unchanged file alone" "200001010000" "$(date -r "$tmp/Config/Version.xcconfig" +%Y%m%d%H%M)"
VERSION_OUT="$tmp/elsewhere.xcconfig" "$here/version.sh" --write
if [ -f "$tmp/elsewhere.xcconfig" ]; then echo "ok   VERSION_OUT"; else echo "FAIL VERSION_OUT"; fails=$((fails + 1)); fi
git -C "$tmp" tag v1.0.1-rc1; commit "fix: four"
expect "suffixed tags ignored" "1.0.1" "$("$here/version.sh" --marketing)"
expect "suffixed tags ignored in --tag" "v1.0.0" "$("$here/version.sh" --tag)"
git -C "$tmp" tag v1.0.9; git -C "$tmp" tag v1.0.10
expect "tags compare numerically" "v1.0.10" "$("$here/version.sh" --tag)"
git -C "$tmp" tag -d v1.0.9 v1.0.10 v1.0.1-rc1 >/dev/null
git -C "$tmp" checkout -q -b side; commit "feat: side"; git -C "$tmp" tag v9.0.0; git -C "$tmp" checkout -q -
expect "tags not reachable from HEAD ignored" "v1.0.0" "$("$here/version.sh" --tag)"
git -C "$tmp" tag -d v9.0.0 >/dev/null
echo scratch > "$tmp/f"; git -C "$tmp" add f; git -C "$tmp" commit -q -m "chore: add f"; echo changed > "$tmp/f"
case "$("$here/version.sh" --full)" in *.dirty) echo "ok   dirty marker";; *) echo "FAIL dirty marker"; fails=$((fails + 1));; esac
case "$("$here/version.sh" --commit)" in *-dirty) echo "ok   dirty commit";; *) echo "FAIL dirty commit"; fails=$((fails + 1));; esac
expect "dirty leaves marketing alone" "1.0.1" "$("$here/version.sh" --marketing)"
bare="$(mktemp -d)"; trap 'rm -rf "$tmp" "$bare"' EXIT
expect "no git repo marketing" "0.0.1" "$(VERSION_REPO="$bare" "$here/version.sh" --marketing)"
expect "no git repo build" "1" "$(VERSION_REPO="$bare" "$here/version.sh" --build)"
expect "no git repo commit" "unknown" "$(VERSION_REPO="$bare" "$here/version.sh" --commit)"
expect "bad flag exits 2" "2" "$("$here/version.sh" --nope 2>/dev/null; echo $?)"
[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "version tests ok"
