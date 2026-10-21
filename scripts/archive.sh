#!/usr/bin/env bash
# make archive: produce build/<App>.xcarchive for the generic iOS device.
# Signed (default): automatic signing with DEVELOPMENT_TEAM; if the ASC_* env vars are set, xcodebuild
#   authenticates headlessly with the API key (-allowProvisioningUpdates), otherwise it uses the Apple ID
#   signed in to Xcode. This may create/update the App ID and profiles on the Apple account.
# Unsigned (SIGNING=none): proves the archive compiles; the result cannot be exported or uploaded.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
generate_project
mkdir -p "$BUILD_DIR"; rm -rf "$ARCHIVE_PATH"

args=(-project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination "generic/platform=iOS"
      -archivePath "$ARCHIVE_PATH" -derivedDataPath "$DERIVED")
if [ "${SIGNING:-}" = "none" ]; then
  echo "archiving UNSIGNED (proof only; cannot be uploaded)"
  args+=(CODE_SIGNING_ALLOWED=NO)
else
  "$(dirname "${BASH_SOURCE[0]}")/doctor.sh" --signing >/dev/null || die "signing prerequisites missing: run 'make doctor SIGNING=1'"
  args+=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID")
  while IFS= read -r a; do [ -n "$a" ] && args+=("$a"); done < <(asc_auth_args)
fi
xcodebuild "${args[@]}" archive -quiet
echo "archive ok: ${ARCHIVE_PATH#"$ROOT"/} (build $(cfg CURRENT_PROJECT_VERSION), version $(cfg MARKETING_VERSION))"
