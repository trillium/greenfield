#!/usr/bin/env bash
# make build: generate the project from project.yml, then compile.
# Usage: build.sh [--device] [SCHEME]   simulator build, no signing needed; --device is an iphoneos-SDK compile check with signing
#        disabled (touches no Apple account). SCHEME defaults to the app.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
generate_project
if [ "${1:-}" = "--device" ]; then dest="generic/platform=iOS"; shift; else dest="$(sim_destination)"; fi
scheme="${1:-$SCHEME}"
echo "building $scheme for: $dest"
xcodebuild -project "$PROJECT" -scheme "$scheme" -destination "$dest" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build -quiet
echo "build ok"
