#!/usr/bin/env bash
# make test-ui: run the UI tests (Apple's accessibility audit on every tab and the first-run screen) on an iOS simulator.
# Extra arguments go to xcodebuild, e.g. -only-testing:DictationAppUITests/AccessibilityAuditUITests/testHelpTabPassesTheAccessibilityAudit.
# A test that fails is run once more (the first launch on a cold simulator is sometimes refused).
# STRICT=1 ignores App/UITests/audit-known-findings.txt and fails on every finding.
# Slower than `make test`, which runs only the unit tests. No signing, no Apple account.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
generate_project
dest="$(sim_destination)"
echo "UI testing $SCHEME on: $dest"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/test-ui.xcresult"
TEST_RUNNER_AUDIT_STRICT="${STRICT:-0}" xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$dest" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$BUILD_DIR/test-ui.xcresult" \
  -only-testing:DictationAppUITests "$@" -retry-tests-on-failure -test-iterations 2 -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test -quiet
echo "UI tests ok (result bundle: ${BUILD_DIR#"$ROOT"/}/test-ui.xcresult)"
