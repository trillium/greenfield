#!/bin/bash
# Lists how big each downloaded speech model is on the phone (from the spike app's data container), largest first.
# Usage: tools/spike/model_sizes.sh [DEVICE]    (default: the first connected device)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle="$(grep -E '^PRODUCT_BUNDLE_IDENTIFIER' "$root/Config/Base.xcconfig" | sed -E 's/^[^=]*=[[:space:]]*//').spike"
device="${1:-}"
[ -z "$device" ] || device="--device $device"
for sub in "Library/Application Support" "Documents"; do
  # shellcheck disable=SC2086
  xcrun devicectl device info files $device --domain-type appDataContainer --domain-identifier "$bundle" --subdirectory "$sub" 2>/dev/null
done | python3 -c '
import re, sys
units = {"bytes": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9}
totals = {}
for line in sys.stdin:
    m = re.match(r"^(\S.*?)\s{2,}Writable, Readable\s{2,}([\d.,]+) (bytes|KB|MB|GB)\s", line)
    if not m:
        continue
    path, size = m.group(1), float(m.group(2).replace(",", "")) * units[m.group(3)]
    parts = path.split("/")
    key = "/".join(parts[:3]) if parts[0] in ("FluidAudio", "MoonshineModels", "huggingface") else None
    if parts[0] == "huggingface" and len(parts) > 4:
        key = "/".join(parts[:5])
    if key:
        totals[key] = totals.get(key, 0) + size
for key, size in sorted(totals.items(), key=lambda kv: -kv[1]):
    print(f"{size / 1e6:9.0f} MB  {key}")
'
