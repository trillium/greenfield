#!/usr/bin/env bash
# make test: run the unit test target on an iOS simulator. No signing, no Apple account.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
generate_project
dest="$(sim_destination)"
echo "testing $SCHEME on: $dest"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/test.xcresult"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$dest" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$BUILD_DIR/test.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test -quiet
echo "tests ok (result bundle: ${BUILD_DIR#"$ROOT"/}/test.xcresult)"
