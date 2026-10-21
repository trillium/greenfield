#!/usr/bin/env bash
# Tests for the commit tooling: the message validator (good and bad examples), the hook installer,
# check-commits, suggest-bump, the env loader and check-parity. Uses throwaway repos in a temp dir.
# Usage: test-commit-tooling.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
# Throwaway repos must not inherit the caller's git configuration (hooks paths, identities, signing).
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }
assert() { # assert NAME CMD... (passes when CMD succeeds)
  local name="$1"; shift
  if "$@"; then ok; else bad "$name"; fi
}
check() { # check NAME EXPECTED-EXIT CMD...
  local name="$1" want="$2"; shift 2
  local got=0; "$@" >"$tmp/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then ok; else bad "$name (exit $got, wanted $want): $(head -c 300 "$tmp/out")"; fi
}
valid()   { check "valid: $1" 0 "$root/scripts/check-commit-msg.sh" -m "$1"; }
invalid() { check "invalid: $1" 1 "$root/scripts/check-commit-msg.sh" -m "$1"; }

# --- the validator: good subjects
for m in \
  "feat: add status route" \
  "fix(mac): reject empty text" \
  "feat(mac)!: drop the v1 api" \
  "docs: explain the key store" \
  "chore: bump swift tools version" \
  "refactor(core/http): split the parser" \
  "test: cover duplicate ids" \
  "perf: cache the tailnet address" \
  "build: pin the swift toolchain" \
  "ci: run make check on push" \
  "revert: undo the listener change" \
  "feat(mac): HTTP keep-alive for status" \
  "fix: embed the default name" \
  "fix: parse a string port" \
  "feat: ios build settings" \
  "Merge branch 'feature' into main" \
  $'feat: add x\n\nA body after a blank line.\n\nBREAKING CHANGE: the old flag is gone, use --new' \
  "feat: $(printf 'a%.0s' {1..66})"; do valid "$m"; done

# --- the validator: bad subjects
for m in \
  "" \
  "added a thing" \
  "Update the readme" \
  "feat add thing" \
  "feat:add thing" \
  "feat : add thing" \
  "feature: add thing" \
  "feat: Add thing" \
  "feat: added thing" \
  "feat: adds thing" \
  "fix: fixing the thing" \
  "feat: add thing." \
  "feat: " \
  "feat(Mac): add thing" \
  "feat(): add thing" \
  "feat(a b): add thing" \
  "feat!add: thing" \
  "feat: $(printf 'a%.0s' {1..68})" \
  $'feat: add x\nbody without a blank line' \
  $'feat: add x\n\nBREAKING CHANGE removes y' \
  $'feat: add x\n\nBREAKING-CHANGE:'; do invalid "$m"; done

# --- message files (what git passes to the hook): comments are ignored, scissors cut the rest
printf 'feat: add x\n# a comment\n' > "$tmp/m1";                         check "file with comment" 0 "$root/scripts/check-commit-msg.sh" "$tmp/m1"
printf '# only comments\n' > "$tmp/m2";                                  check "file with only comments" 1 "$root/scripts/check-commit-msg.sh" "$tmp/m2"
printf 'Merge branch x\n' > "$tmp/m3";                                   check "merge message file" 0 "$root/scripts/check-commit-msg.sh" "$tmp/m3"
printf 'fix: add x\n# ------------------------ >8 ------------------------\nBAD LINE\n' > "$tmp/m4"
check "file with scissors" 0 "$root/scripts/check-commit-msg.sh" "$tmp/m4"
printf 'fix: add x\n' | check "stdin" 0 "$root/scripts/check-commit-msg.sh" -
check "missing file" 2 "$root/scripts/check-commit-msg.sh" "$tmp/nope"

# --- a throwaway repo with the scripts, for the hook, check-commits and suggest-bump
repo="$tmp/repo"; mkdir -p "$repo/scripts"
cp "$root"/scripts/*.sh "$repo/scripts/"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.invalid; git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
commit() { git -C "$repo" commit -q --allow-empty --no-verify -m "$1"; }
run() { (cd "$repo" && "$@"); }
commit "An old commit that predates the convention"
git -C "$repo" branch -q base

check "hook install" 0 run scripts/install-hooks.sh
check "hook install is repeatable" 0 run scripts/install-hooks.sh
assert "hook is executable" test -x "$repo/.git/hooks/commit-msg"
if (cd "$repo" && git commit -q --allow-empty -m "Bad message" >/dev/null 2>&1); then bad "hook rejects a bad message"; else ok; fi
if (cd "$repo" && git commit -q --allow-empty -m "fix: reject a bad message" >/dev/null 2>&1); then ok; else bad "hook accepts a good message"; fi

printf '#!/bin/sh\necho mine\n' > "$repo/.git/hooks/commit-msg"
check "foreign hook is not overwritten" 1 run scripts/install-hooks.sh
assert "foreign hook content kept" grep -q 'echo mine' "$repo/.git/hooks/commit-msg"

git -C "$repo" config core.hooksPath "$tmp/elsewhere"
check "a core.hooksPath outside the repo is refused" 1 run scripts/install-hooks.sh
git -C "$repo" config core.hooksPath .githooks
check "an in-repo core.hooksPath gets the hook" 0 run scripts/install-hooks.sh
assert "hook written under the configured path" test -x "$repo/.githooks/commit-msg"
check "an existing validator hook is left alone" 0 run scripts/install-hooks.sh
git -C "$repo" config --unset core.hooksPath
rm -rf "$repo/.githooks"

check "check-commits ignores history before the base" 0 run scripts/check-commits.sh base
commit "Sloppy message"
check "check-commits finds a bad commit" 1 run scripts/check-commits.sh base
git -C "$repo" reset -q --hard HEAD~1
commit "feat(core): add a thing"
git -C "$repo" merge -q --no-ff -m "Merge side" HEAD 2>/dev/null || true
check "check-commits passes good commits" 0 run scripts/check-commits.sh base
git -C "$repo" branch -q second HEAD~1
printf '# exempt up to here\nsecond\n' > "$repo/.commit-baseline"
check "check-commits reads .commit-baseline" 0 run scripts/check-commits.sh
printf 'nope\n' > "$repo/.commit-baseline"
check "check-commits with an unknown baseline" 2 run scripts/check-commits.sh
rm "$repo/.commit-baseline"
check "check-commits with an unknown base" 2 run scripts/check-commits.sh nope

# --- suggest-bump
bump() { (cd "$repo" && scripts/suggest-bump.sh --level); }
next() { (cd "$repo" && scripts/suggest-bump.sh --next); }
assert "feat suggests minor" test "$(bump)" = minor
assert "first release is 0.1.0" test "$(next)" = 0.1.0
git -C "$repo" tag -a v1.2.3 -m v1.2.3
assert "nothing since the tag" test "$(bump)" = none
commit "docs: explain things"; commit "chore: tidy"
assert "docs/chore suggest no bump" test "$(bump)" = none
commit "fix: reject a bad port"
assert "fix suggests patch 1.2.4" test "$(bump) $(next)" = "patch 1.2.4"
commit "perf: speed up the parser"
assert "perf suggests patch" test "$(bump)" = patch
commit "feat: add a route"
assert "feat suggests minor 1.3.0" test "$(bump) $(next)" = "minor 1.3.0"
commit "refactor(core)!: rename the core module"
assert "breaking after 1.x suggests major 2.0.0" test "$(bump) $(next)" = "major 2.0.0"
git -C "$repo" tag -a v0.4.0 -m v0.4.0 HEAD
commit $'fix: change the wire format\n\nBREAKING CHANGE: old clients cannot connect'
git -C "$repo" tag -d v1.2.3 >/dev/null
assert "breaking while MAJOR is 0 suggests minor 0.5.0" test "$(bump) $(next)" = "minor 0.5.0"
(cd "$repo" && scripts/suggest-bump.sh) > "$tmp/summary"
assert "summary mentions the bump" grep -q 'suggested bump:  minor' "$tmp/summary"

# --- the env loader: parsed not executed, existing environment wins, require_env reports
cat > "$tmp/env" <<ENVFILE
# comment
PLAIN=1
export EXPORTED=2
QUOTED="three words"
SINGLE='x y'
SET_ALREADY=file
BAD LINE
\$(touch $tmp/pwned)=1
ENVFILE
out="$(ENV_FILE="$tmp/env" SET_ALREADY=env bash -c ". '$root/scripts/load-env.sh'; echo \"\$PLAIN|\$EXPORTED|\$QUOTED|\$SINGLE|\$SET_ALREADY\"")"
assert "env loader parses KEY=VALUE lines ($out)" test "$out" = "1|2|three words|x y|env"
assert "env loader does not execute the file" test ! -e "$tmp/pwned"
check "require_env on a missing variable" 1 env ENV_FILE="$tmp/env" bash -c ". '$root/scripts/load-env.sh'; require_env NOT_THERE"
check "require_env on a set variable" 0 env ENV_FILE="$tmp/env" bash -c ". '$root/scripts/load-env.sh'; require_env PLAIN"

# --- check-parity, on two throwaway copies of the manifest's files
a="$tmp/a"; b="$tmp/b"; mkdir -p "$a/scripts" "$b/scripts"
cp "$root/scripts/check-parity.sh" "$root/scripts/parity-manifest.txt" "$a/scripts/"
while IFS= read -r p; do
  case "$p" in ""|"#"*) continue ;; esac
  mkdir -p "$a/$(dirname "$p")"; [ -f "$a/$p" ] || echo "content of $p" > "$a/$p"
done < "$root/scripts/parity-manifest.txt"
cp -R "$a/." "$b/"
check "parity of identical copies" 0 "$a/scripts/check-parity.sh" "$b"
echo "# drift" >> "$b/docs/commits.md"
check "parity reports drift" 1 "$a/scripts/check-parity.sh" "$b"
assert "parity names the drifted file" grep -q 'DRIFT  docs/commits.md' "$tmp/out"
rm "$b/docs/commits.md"
check "parity reports a file only here" 1 "$a/scripts/check-parity.sh" "$b"
assert "parity names the file only here" grep -q 'ONLY-HERE  docs/commits.md' "$tmp/out"
check "parity without a sibling" 2 "$a/scripts/check-parity.sh"
check "parity against itself" 2 "$a/scripts/check-parity.sh" "$a"

echo "commit tooling tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
