#!/usr/bin/env bash
# Prints the directory of the ParrotKit checkout project.yml depends on (the shared package for the noise/Parrot layer, health and onboarding).
# Order: PARROT_KIT_DIR, ../parrot-kit, the sibling of this repo's main checkout, ~/code/parrot-kit. Nothing is cloned or fetched.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
main_parent=""
common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -n "$common" ] && main_parent="$(dirname "$(dirname "$common")")"
for candidate in "${PARROT_KIT_DIR:-}" "$root/../parrot-kit" "$main_parent/parrot-kit" "$HOME/code/parrot-kit"; do
  [ -n "$candidate" ] || continue
  if [ -f "$candidate/Package.swift" ]; then (cd "$candidate" && pwd -P); exit 0; fi
done
echo "error: cannot find the ParrotKit checkout (needs Package.swift); set PARROT_KIT_DIR" >&2
exit 1
