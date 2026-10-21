#!/usr/bin/env bash
# Tests for kit-version.sh against throwaway kit directories. Run by `make check`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
expect() { # expect LABEL WANT GOT
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fails=$((fails + 1)); fi
}
fake_kit() { # fake_kit DIR VERSION
  mkdir -p "$1/Sources/ParrotKit"
  printf 'public enum ParrotKitInfo {\n    public static let version = "%s"\n    public static let soundPackFormat = 1\n}\n' "$2" > "$1/Sources/ParrotKit/Version.swift"
}
fake_kit "$tmp/a" 0.5.0
expect "reads the kit's version" "0.5.0" "$("$here/kit-version.sh" "$tmp/a")"
fake_kit "$tmp/b" 0.12.7
expect "follows a bump with no edit here" "0.12.7" "$("$here/kit-version.sh" "$tmp/b")"
KIT_OUT="$tmp/Kit.xcconfig" "$here/kit-version.sh" --write "$tmp/b"
expect "xcconfig output" "GREENFIELD_KIT_REQUIRED = 0.12.7" "$(grep -v '^//' "$tmp/Kit.xcconfig")"
fake_kit "$tmp/b" 0.13.0
KIT_OUT="$tmp/Kit.xcconfig" "$here/kit-version.sh" --write "$tmp/b"
expect "xcconfig follows the kit" "GREENFIELD_KIT_REQUIRED = 0.13.0" "$(grep -v '^//' "$tmp/Kit.xcconfig")"
mkdir -p "$tmp/c/Sources/ParrotKit"; echo 'public enum ParrotKitInfo {}' > "$tmp/c/Sources/ParrotKit/Version.swift"
if "$here/kit-version.sh" "$tmp/c" 2>/dev/null; then expect "a kit with no version is refused" refused accepted; else echo "ok   a kit with no version is refused"; fi
if "$here/kit-version.sh" "$tmp/none" 2>/dev/null; then expect "a missing kit is refused" refused accepted; else echo "ok   a missing kit is refused"; fi
real="$("$here/kit-version.sh")"
case "$real" in [0-9]*.[0-9]*.[0-9]*) echo "ok   the real kit reads as $real" ;; *) echo "FAIL the real kit read as '$real'"; fails=$((fails + 1)) ;; esac
[ "$fails" = 0 ] || { echo "$fails kit-version test(s) failed" >&2; exit 1; }
echo "kit-version tests ok"
