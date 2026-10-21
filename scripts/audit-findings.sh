#!/usr/bin/env bash
# Prints every accessibility audit finding (what and which element) from the last `make test-ui` run.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
xcrun xcresulttool export attachments --path "$BUILD_DIR/test-ui.xcresult" --output-path "$out" >/dev/null
python3 - "$out" <<'PY'
import json, os, sys
d = sys.argv[1]
for t in json.load(open(os.path.join(d, "manifest.json"))):
    for a in t.get("attachments", []):
        if "AUDIT FINDING" in a.get("suggestedHumanReadableName", ""):
            print(t["testIdentifier"].split("/")[-1], "->", open(os.path.join(d, a["exportedFileName"])).read().split("\n")[0])
PY
