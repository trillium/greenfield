#!/usr/bin/env bash
# Wire up the commit-msg hook that runs scripts/check-commit-msg.sh. Bash 3.2 compatible.
# Usage: install-hooks.sh
# The hooks directory is the repo's own core.hooksPath (a path inside the repo, such as .githooks)
# or, when none is set, the shared .git/hooks. A commit-msg hook that already runs the validator is
# left alone; one that does not is never overwritten (the script says how to chain it and exits 1);
# a missing one is created. A core.hooksPath outside the repo (a machine-wide setting) is refused.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
marker="check-commit-msg.sh"

# Read the repo's own setting, not command-line or global overrides.
configured="$(git config --local --get core.hooksPath || true)"
case "$configured" in
  "")  dir="$common/hooks" ;;
  /*)  dir="$configured" ;;
  *)   dir="$root/$configured" ;;
esac
case "$dir" in
  "$root"/*|"$common"/*) ;;
  *) echo "install-hooks: core.hooksPath ($configured) is outside this repository; not touching it." >&2
     echo "Run 'git config core.hooksPath .githooks' (or unset it) and try again." >&2
     exit 1 ;;
esac
hook="$dir/commit-msg"

if [ -f "$hook" ]; then
  if grep -q "$marker" "$hook"; then
    echo "commit-msg hook already runs $marker: ${hook#"$root"/}"
    exit 0
  fi
  {
    echo "install-hooks: $hook exists and does not run $marker; left untouched."
    echo "Add this line to it (after the shebang and any 'set -e') to enforce commit messages:"
    echo "  \"\$(git rev-parse --show-toplevel)/scripts/$marker\" \"\$1\" || exit 1"
  } >&2
  exit 1
fi

mkdir -p "$dir"
cat > "$hook" <<'HOOK'
#!/usr/bin/env sh
# Validate the commit message (docs/commits.md). A checkout without the validator is let through.
root="$(git rev-parse --show-toplevel)"
[ -x "$root/scripts/check-commit-msg.sh" ] || exit 0
exec "$root/scripts/check-commit-msg.sh" "$1"
HOOK
chmod +x "$hook"
echo "commit-msg hook installed: ${hook#"$root"/}"
