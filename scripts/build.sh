#!/usr/bin/env bash
# make build: generate the project from project.yml, then compile.
# Usage: build.sh            simulator build, no signing needed
#        build.sh --device   iphoneos-SDK compile check with signing disabled (touches no Apple account)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
generate_project
if [ "${1:-}" = "--device" ]; then dest="generic/platform=iOS"; else dest="$(sim_destination)"; fi
echo "building $SCHEME for: $dest"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$dest" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build -quiet
echo "build ok"
