#!/usr/bin/env bash
# make doctor: check the machine and the repo are ready to build, and (separately) to ship to TestFlight.
# Usage: doctor.sh [--signing]   --signing turns signing prerequisites from WARN into FAIL.
# Read-only: touches nothing, calls no Apple service, never prints key contents.
# shellcheck disable=SC2015  # pass/warn/fail helpers always return 0, so A && B || C is safe here
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

strict=0; [ "${1:-}" = "--signing" ] && strict=1
fails=0; warns=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
signing() { if [ "$strict" = 1 ]; then fail "$*"; else warn "$* (needed for archive; run 'make doctor SIGNING=1' to enforce)"; fi; }

echo "== Toolchain =="
if command -v xcodebuild >/dev/null 2>&1 && ver="$(xcodebuild -version 2>/dev/null | sed -n 1p)"; then
  major="$(printf '%s' "$ver" | sed -E 's/Xcode ([0-9]+).*/\1/')"
  if [ "${major:-0}" -ge 15 ] 2>/dev/null; then pass "$ver ($(xcode-select -p))"; else fail "Xcode 15+ required, found: $ver"; fi
else
  fail "xcodebuild not usable (install Xcode, then: sudo xcode-select -s /Applications/Xcode.app)"
fi
if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then pass "Xcode first-launch / license ok"
else fail "Xcode first-launch not complete (run: sudo xcodebuild -runFirstLaunch; sudo xcodebuild -license accept)"; fi
if xcrun simctl list devices available 2>/dev/null | grep -qE '^[[:space:]]+iPhone '; then pass "iPhone simulator available"
else fail "no iPhone simulator (xcodebuild -downloadPlatform iOS)"; fi
command -v xcodegen >/dev/null 2>&1 && pass "xcodegen $(xcodegen --version | sed 's/Version: //')" || fail "xcodegen missing (brew install xcodegen)"
command -v swiftlint >/dev/null 2>&1 && pass "swiftlint $(swiftlint --version)" || warn "swiftlint missing (brew install swiftlint); make check needs it"
command -v shellcheck >/dev/null 2>&1 && pass "shellcheck present" || warn "shellcheck missing (brew install shellcheck); make check lints scripts with it"
command -v gitleaks >/dev/null 2>&1 && pass "gitleaks present" || warn "gitleaks missing (brew install gitleaks); the pre-commit second-opinion scan is skipped"

echo "== Sound detector (make core) =="
for f in include/parrot.h device/libparrot_core.a sim/libparrot_core.a resources/parrot-model.bin; do
  if [ -f "$ROOT/.parrot-core/$f" ]; then pass ".parrot-core/$f staged"; else fail ".parrot-core/$f missing: run 'make core' (needs the sibling parrot-app checkout)"; fi
done

echo "== Project identity (Config/Base.xcconfig) =="
if is_placeholder "$APP_NAME"; then fail "APP_NAME unset/placeholder"; else pass "APP_NAME=$APP_NAME"; fi
if is_placeholder "$BUNDLE_ID"; then signing "PRODUCT_BUNDLE_IDENTIFIER is unset or still com.example.* ($BUNDLE_ID)"; else pass "bundle id $BUNDLE_ID"; fi
if printf '%s' "$TEAM_ID" | grep -qE '^[A-Z0-9]{10}$'; then pass "DEVELOPMENT_TEAM=$TEAM_ID"
else signing "DEVELOPMENT_TEAM is not a 10-character team id (Apple Developer > Membership > Team ID)"; fi
build="$(cfg CURRENT_PROJECT_VERSION)"
printf '%s' "$build" | grep -qE '^[0-9]+$' && pass "build number $build, version $(cfg MARKETING_VERSION) (from git tags)" || fail "CURRENT_PROJECT_VERSION must be an integer, got '$build'"

echo "== Signing prerequisites (hand-made by the account holder; see docs/signing.md) =="
ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if printf '%s' "$ids" | grep -q "Apple Distribution"; then pass "Apple Distribution certificate in Keychain"
else warn "no Apple Distribution certificate in Keychain (fine if the API key has App Manager role: Xcode can use cloud signing)"; fi
if printf '%s' "$ids" | grep -qE "Apple Development|iPhone Developer"; then pass "Apple Development certificate in Keychain"
else warn "no Apple Development certificate in Keychain (needed only for running on a real device)"; fi
missing=""; for v in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do [ -n "${!v:-}" ] || missing="$missing $v"; done
if [ -n "$missing" ]; then
  signing "App Store Connect API key env vars not set:$missing"
else
  pass "ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH are set"
  printf '%s' "$ASC_KEY_ID" | grep -qE '^[A-Z0-9]{10}$' && pass "ASC_KEY_ID shape ok" || fail "ASC_KEY_ID should be 10 characters [A-Z0-9]"
  printf '%s' "$ASC_ISSUER_ID" | grep -qiE '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' && pass "ASC_ISSUER_ID shape ok" || fail "ASC_ISSUER_ID should be a UUID"
  if [ -f "$ASC_KEY_PATH" ]; then
    pass "ASC_KEY_PATH file exists"
    key_abs="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)/$(basename "$ASC_KEY_PATH")"
    case "$key_abs" in "$ROOT"/*) fail "ASC key lives inside this repo ($key_abs): move it out; keys must never be in the work tree" ;; *) pass "ASC key is outside the repo" ;; esac
    mode="$(stat -f %Lp "$ASC_KEY_PATH")"
    case "$mode" in *00) pass "ASC key permissions $mode" ;; *) warn "ASC key permissions $mode: run chmod 600 on it" ;; esac
  else
    fail "ASC_KEY_PATH does not point at a file"
  fi
fi

echo "== Result =="
echo "$fails failure(s), $warns warning(s)"
[ "$fails" -eq 0 ]
