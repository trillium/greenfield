#!/usr/bin/env bash
# Validate every commit message on this branch since the base branch (docs/commits.md).
# Usage: check-commits.sh [BASE]     merge commits are skipped.
# BASE is the first of: the argument, $COMMITS_BASE, the first line of .commit-baseline (a ref or sha, '#' comments
# allowed), main, origin/main. History reachable from BASE is exempt, so only the commits you are adding are checked.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="${1:-${COMMITS_BASE:-}}"
if [ -z "$base" ] && [ -f "$(git rev-parse --show-toplevel)/.commit-baseline" ]; then
  base="$(grep -vE '^[[:space:]]*(#|$)' "$(git rev-parse --show-toplevel)/.commit-baseline" | head -n 1 | tr -d '[:space:]')"
fi
if [ -z "$base" ]; then
  for c in main origin/main; do
    if git rev-parse -q --verify "$c^{commit}" >/dev/null; then base="$c"; break; fi
  done
fi
[ -n "$base" ] || { echo "check-commits: no base to compare against (no .commit-baseline, main or origin/main); pass BASE=<ref>" >&2; exit 2; }
git rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "check-commits: unknown base '$base'" >&2; exit 2; }

total=0; bad=0
for sha in $(git rev-list --reverse --no-merges "$base..HEAD"); do
  total=$((total + 1))
  if ! git log -1 --format=%B "$sha" | "$here/check-commit-msg.sh" - 2>"${TMPDIR:-/tmp}/check-commits.$$"; then
    bad=$((bad + 1))
    echo "$(git log -1 --format='%h' "$sha"):" >&2
    sed 's/^/  /' "${TMPDIR:-/tmp}/check-commits.$$" >&2
  fi
done
rm -f "${TMPDIR:-/tmp}/check-commits.$$"

if [ "$bad" -gt 0 ]; then
  echo "check-commits: $bad of $total commit(s) since $base have invalid messages (fix with 'git rebase -i $base', reword)" >&2
  exit 1
fi
echo "check-commits: $total commit(s) since $base ok"
