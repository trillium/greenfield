#!/usr/bin/env bash
# Cut a release: check the tree, bump via an annotated git tag vX.Y.Z, update CHANGELOG.md.
# Usage: cut-release.sh <major|minor|patch> [--dry-run]
# Run on main after the change PRs have merged. Never pushes; prints the push steps. See docs/versioning.md.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
level="${1:-}"; dry="${2:-}"
case "$level" in major|minor|patch) ;; *) die "usage: cut-release.sh <major|minor|patch> [--dry-run]" ;; esac
cd "$ROOT"

[ -z "$(git status --porcelain)" ] || die "working tree is not clean; commit or stash first"
[ "$dry" = "--dry-run" ] || [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "releases are cut from main (use --dry-run to preview)"

last="$("$ROOT/scripts/version.sh" --tag)"
base="${last#v}"; base="${base:-0.0.0}"
IFS=. read -r maj min pat <<EOT
$base
EOT
case "$level" in
  major) maj=$((maj + 1)); min=0; pat=0 ;;
  minor) min=$((min + 1)); pat=0 ;;
  patch) pat=$((pat + 1)) ;;
esac
new="$maj.$min.$pat"
git rev-parse -q --verify "refs/tags/v$new" >/dev/null && die "tag v$new already exists"

range="HEAD"; [ -z "$last" ] || range="$last..HEAD"
[ "$(git rev-list --count "$range")" -gt 0 ] || die "no commits since ${last:-the start}; nothing to release"

section() { # section HEADING TYPE-REGEX
  local lines
  lines="$(git log --no-merges --format=%s "$range" | grep -E "^($2)(\([^)]*\))?!?: " | sed -E 's/^[a-z]+(\([^)]*\))?!?: /- /' || true)"
  [ -z "$lines" ] || printf '### %s\n%s\n\n' "$1" "$lines"
}
breaking="$(git log --no-merges --format=%s "$range" | grep -E '^[a-z]+(\([^)]*\))?!: ' | sed -E 's/^[a-z]+(\([^)]*\))?!: /- /' || true)"
entry="## [$new] - $(date +%Y-%m-%d)

$(section Added 'feat')$(section Fixed 'fix')$(section Changed 'perf|refactor')"
[ -z "$breaking" ] || entry="$entry### Breaking
$breaking

"

if [ "$dry" = "--dry-run" ]; then printf 'would tag v%s (was %s)\n\n%s\n' "$new" "${last:-none}" "$entry"; exit 0; fi

header='# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: docs/versioning.md.
'
tmp="$(mktemp)"
{
  if [ -f CHANGELOG.md ]; then
    # keep everything before the first release heading, insert the new entry, then the older entries
    awk '/^## \[/{exit} {print}' CHANGELOG.md
    printf '%s\n' "$entry"
    awk 'f{print} /^## \[/&&!f{f=1; print}' CHANGELOG.md
  else
    printf '%s\n%s\n' "$header" "$entry"
  fi
} > "$tmp"
mv "$tmp" CHANGELOG.md
git add CHANGELOG.md
git commit -q -m "chore(release): v$new"
git tag -a "v$new" -m "v$new"
echo "release v$new committed and tagged locally. Next:"
echo "  1. git push origin main"
echo "  2. git push origin v$new"
echo "  3. make archive   (build number is stamped from git; uploading is a separate manual step)"
