#!/usr/bin/env bash
# Suggest the semver bump from the Conventional Commits since the last tag (docs/commits.md).
# Usage: suggest-bump.sh              human-readable summary
#        suggest-bump.sh --level      only major|minor|patch|none
#        suggest-bump.sh --next       only the next version (empty when there is nothing to release)
# Commits that do not follow the convention (older history) count as "no bump". Never writes anything.
set -euo pipefail

mode="${1:-}"
case "$mode" in ""|--level|--next) ;; *) echo "usage: suggest-bump.sh [--level|--next]" >&2; exit 2 ;; esac

last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
base="${last#v}"; base="${base:-0.0.0}"
range="HEAD"; [ -z "$last" ] || range="$last..HEAD"

major=0; minor=0; patch=0; total=0
subject_re='^([a-z]+)(\([^)]*\))?(!)?: '
for sha in $(git rev-list --no-merges "$range"); do
  total=$((total + 1))
  msg="$(git log -1 --format=%B "$sha")"
  subject="$(printf '%s\n' "$msg" | head -n 1)"
  if [[ "$subject" =~ $subject_re ]]; then
    type="${BASH_REMATCH[1]}"
    [ -z "${BASH_REMATCH[3]}" ] || major=$((major + 1))
    case "$type" in feat) minor=$((minor + 1)) ;; fix|perf) patch=$((patch + 1)) ;; esac
  fi
  if printf '%s\n' "$msg" | tail -n +2 | grep -qE '^BREAKING[ -]CHANGE: '; then major=$((major + 1)); fi
done

IFS=. read -r b_major b_minor b_patch <<EOT
$base
EOT
level="none"
if [ "$major" -gt 0 ]; then
  # While MAJOR is 0 a breaking change bumps MINOR; 1.0.0 is a deliberate decision, not a side effect.
  if [ "$b_major" -eq 0 ]; then level="minor"; else level="major"; fi
elif [ "$minor" -gt 0 ]; then level="minor"
elif [ "$patch" -gt 0 ]; then level="patch"
fi

next=""
case "$level" in
  major) next="$((b_major + 1)).0.0" ;;
  minor) next="$b_major.$((b_minor + 1)).0" ;;
  patch) next="$b_major.$b_minor.$((b_patch + 1))" ;;
esac

case "$mode" in
  --level) echo "$level" ;;
  --next) echo "$next" ;;
  *)
    echo "last tag:        ${last:-none (counting from 0.0.0)}"
    echo "commits since:   $total ($major breaking, $minor feat, $patch fix/perf)"
    if [ "$level" = none ]; then
      echo "suggested bump:  none (no feat, fix, perf or breaking commits)"
    else
      echo "suggested bump:  $level  ->  $next"
    fi ;;
esac
