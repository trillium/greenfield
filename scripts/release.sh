#!/usr/bin/env bash
# Release gate: print the suggested semver bump from the commits since the last tag and require a
# changelog section for the version about to be released. Writes nothing and tags nothing.
# Usage: release.sh [X.Y.Z]     X.Y.Z defaults to the suggested next version (docs/commits.md)
# Exit 0 when the changelog has "## [X.Y.Z]" in mac/CHANGELOG.md or CHANGELOG.md; 1 when it does not.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
scripts/suggest-bump.sh
suggested="$(scripts/suggest-bump.sh --next)"
version="${1:-$suggested}"
version="${version#v}"

if [ -z "$version" ]; then
  echo "nothing to release: no feat, fix, perf or breaking commits since the last tag" >&2
  exit 1
fi
printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "release: '$version' is not X.Y.Z" >&2; exit 2; }
[ "$version" = "$suggested" ] || echo "note: releasing $version, the commits suggest ${suggested:-no release}"

for f in mac/CHANGELOG.md CHANGELOG.md; do
  if [ -f "$f" ] && grep -qE "^## \[$version\]" "$f"; then
    echo "changelog: $f has a section for $version"
    echo "next: git tag -a v$version -m v$version   (pushing the branch and tag is a manual step)"
    exit 0
  fi
done
echo "release: no changelog section for $version; add '## [$version] - $(date +%Y-%m-%d)' to CHANGELOG.md first" >&2
exit 1
