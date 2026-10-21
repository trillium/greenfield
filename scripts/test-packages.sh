#!/usr/bin/env bash
# Tests for Config/Package.resolved: every package project.yml pins by version must be pinned here too, at the
# same version, with a full revision. scripts/lib.sh copies this file into the generated workspace, so a package
# whose version is bumped in project.yml without re-pinning here fails this test instead of the build.
# Run by `make check`.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$root" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
fails = 0


def ok(label):
    print(f"ok   {label}")


def bad(label, detail):
    global fails
    fails += 1
    print(f"FAIL {label}: {detail}")


def identity(url):
    """The name a package manager gives a dependency: the URL's last path component, lowercased."""
    name = url.rstrip("/").split("/")[-1]
    return (name[:-4] if name.endswith(".git") else name).lower()


try:
    pins_doc = json.loads((root / "Config" / "Package.resolved").read_text())
except Exception as exc:  # a broken pins file would otherwise only show up as a confusing build failure
    print(f"FAIL pins file parses: {exc}")
    print("1 failure(s)")
    sys.exit(1)
ok("pins file parses")

if pins_doc.get("version") == 3 and isinstance(pins_doc.get("pins"), list):
    ok("pins file is a version 3 pin list")
else:
    bad("pins file is a version 3 pin list", pins_doc.get("version"))

pins = {pin["identity"]: pin for pin in pins_doc["pins"]}
wanted = {}
url = None
for line in (root / "project.yml").read_text().splitlines():
    found = re.match(r"^    url:\s*(\S+)\s*$", line)
    if found:
        url = found.group(1).strip("\"'")
        continue
    version = re.match(r"^    exactVersion:\s*(\S+)\s*$", line)
    if version and url:
        wanted[identity(url)] = version.group(1).strip("\"'")
        url = None

if not wanted:
    bad("project.yml pins packages by version", "no url/exactVersion pairs found")

for name, version in sorted(wanted.items()):
    pin = pins.get(name)
    if pin is None:
        bad(f"{name} is pinned", "Config/Package.resolved has no pin for it")
        continue
    if pin["state"].get("version") == version:
        ok(f"{name} is pinned at {version}")
    else:
        bad(f"{name} is pinned at {version}", f"the pin says {pin['state'].get('version')}")
    if re.fullmatch(r"[0-9a-f]{40}", pin["state"].get("revision", "")):
        ok(f"{name} pin has a full revision")
    else:
        bad(f"{name} pin has a full revision", pin["state"].get("revision"))

for name, pin in sorted(pins.items()):
    if pin.get("location", "").startswith("https://"):
        ok(f"{name} pin names an https location")
    else:
        bad(f"{name} pin names an https location", pin.get("location"))

if fails:
    print(f"{fails} failure(s)")
    sys.exit(1)
print(f"package pin tests ok ({len(pins)} pins, {len(wanted)} named in project.yml)")
PY