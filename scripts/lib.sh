#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Bash 3.2 compatible (macOS system bash).
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/Config"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

# cfg KEY -> value from Config/Base.xcconfig, overridden by Config/Local.xcconfig, then by the
# environment variable of the same name (so `make archive DEVELOPMENT_TEAM=ABCDE12345` works).
cfg() {
  local key="$1" val="" f line
  for f in "$CONFIG_DIR/Base.xcconfig" "$CONFIG_DIR/Version.xcconfig" "$CONFIG_DIR/Local.xcconfig"; do
    [ -f "$f" ] || continue
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$f" | tail -1 || true)"
    [ -n "$line" ] && val="$(printf '%s' "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*(\/\/.*)?$//')"
  done
  if [ -n "${!key:-}" ]; then val="${!key}"; fi
  printf '%s' "$val"
}

APP_NAME="$(cfg APP_NAME)"
BUNDLE_ID="$(cfg PRODUCT_BUNDLE_IDENTIFIER)"
TEAM_ID="$(cfg DEVELOPMENT_TEAM)"
PROJECT="$ROOT/$APP_NAME.xcodeproj"
SCHEME="$APP_NAME"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/$APP_NAME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_DIR/export}"
DERIVED="${DERIVED:-$BUILD_DIR/DerivedData}"

die() { echo "error: $*" >&2; exit 1; }

require_tool() { command -v "$1" >/dev/null 2>&1 || die "required tool not found on PATH: $1 ($2)"; }

generate_project() {
  require_tool xcodegen "brew install xcodegen"
  "$ROOT/scripts/version.sh" --write  # stamp every build from git tags; no hand edits
  (cd "$ROOT" && xcodegen generate --quiet)
}

# Pick a concrete iPhone simulator id, preferring one that is not already booted so we never
# disturb a simulator somebody else is using. Override with SIM_DEST.
sim_destination() {
  if [ -n "${SIM_DEST:-}" ]; then printf '%s' "$SIM_DEST"; return; fi
  local lines pick
  lines="$(xcrun simctl list devices available | grep -E '^[[:space:]]+iPhone ' || true)"
  pick="$(printf '%s\n' "$lines" | grep -v Booted | head -1)"
  [ -n "$pick" ] || pick="$(printf '%s\n' "$lines" | head -1)"
  [ -n "$pick" ] || die "no iPhone simulator available (install a runtime: xcodebuild -downloadPlatform iOS)"
  printf 'platform=iOS Simulator,id=%s' "$(printf '%s' "$pick" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
}

# App Store Connect API key flags for xcodebuild. Values come from env vars only (docs/signing.md);
# nothing here ever echoes the key path's contents.
asc_auth_args() {
  if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    printf '%s\n' -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  fi
}

is_placeholder() { case "$1" in ""|__*|XXXXXXXXXX|com.example.*) return 0 ;; esac; return 1; }

# An archive built with CODE_SIGNING_ALLOWED=NO has an empty SigningIdentity and cannot be uploaded.
archive_is_signed() {
  local id
  id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:SigningIdentity' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)"
  [ -n "$id" ]
}
