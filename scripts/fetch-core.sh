#!/usr/bin/env bash
# make core: stage the sound-detector core, its header and the bundled model into .parrot-core/ (git-ignored).
#
# The detector is a separate Rust library that lives in a sibling checkout (parrot-app). Nothing it produces is committed here:
# the static libraries are build outputs and the model is personal training data. project.yml links the libraries and bundles
# the model from .parrot-core/.
#
# Usage: fetch-core.sh [--build]      --build runs `make lib-ios` in the sibling checkout first
# Environment: PARROT_APP_DIR (default ../parrot-app, then the sibling of this repo's main checkout), PARROT_MODEL (a model file)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CORE_DIR="${CORE_DIR:-$ROOT/.parrot-core}"
main_parent=""
common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -n "$common" ] && main_parent="$(dirname "$(dirname "$common")")"

app_dir=""
for candidate in "${PARROT_APP_DIR:-}" "$ROOT/../parrot-app" "$main_parent/parrot-app" "$HOME/code/parrot-app"; do
  [ -n "$candidate" ] || continue
  if [ -f "$candidate/Makefile" ] && [ -f "$candidate/parrot-core/include/parrot.h" ]; then app_dir="$(cd "$candidate" && pwd -P)"; break; fi
done
[ -n "$app_dir" ] || die "cannot find parrot-app (needs Makefile + parrot-core/include/parrot.h); set PARROT_APP_DIR"
echo "parrot-app: $app_dir"

if [ "${1:-}" = "--build" ]; then make -C "$app_dir" lib-ios >/dev/null; fi

mkdir -p "$CORE_DIR/include" "$CORE_DIR/device" "$CORE_DIR/sim" "$CORE_DIR/resources"
cp "$app_dir/parrot-core/include/parrot.h" "$CORE_DIR/include/parrot.h"
for slice in device:aarch64-apple-ios sim:aarch64-apple-ios-sim; do
  src="$app_dir/target/${slice#*:}/release/libparrot_core.a"
  [ -f "$src" ] || die "missing $src; run: scripts/fetch-core.sh --build"
  cp "$src" "$CORE_DIR/${slice%%:*}/libparrot_core.a"
done

model=""
for candidate in "${PARROT_MODEL:-}" "$app_dir/models/parrot-model.bin"; do
  [ -n "$candidate" ] && [ -f "$candidate" ] && { model="$candidate"; break; }
done
if [ -n "$model" ]; then cp "$model" "$CORE_DIR/resources/parrot-model.bin"
elif [ ! -f "$CORE_DIR/resources/parrot-model.bin" ]; then die "no model found; set PARROT_MODEL=/path/to/parrot-model.bin"; fi

echo "staged in .parrot-core:"
for f in include/parrot.h device/libparrot_core.a sim/libparrot_core.a resources/parrot-model.bin; do
  printf '  %-32s %s bytes\n' "$f" "$(wc -c < "$CORE_DIR/$f" | tr -d ' ')"
done
