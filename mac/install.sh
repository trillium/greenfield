#!/bin/bash
# One command to set up Greenfield's Mac side and finish with "ready".
#
#   mac/install.sh                      build (or use a shipped signed binary), install, start, then guide the rest
#   mac/install.sh --binary FILE        install an already-signed build instead of building one
#
# What it does: installs the SIGNED daemon, loads the launchd agent, opens the Accessibility pane and shows a live
# checklist that turns green as each step lands (the daemon restarts itself when the grant arrives, then proves it can
# type into an app), and ends by printing the add-to-phone link and QR code with a one-line "ready" - or the single
# next step if something is still missing. Safe to run again; it never touches another label, port or HOME unless told.
#
# Options: --binary FILE  --port N  --label L  --prefix DIR  --home CONFIGDIR  --timeout SECONDS
#          --no-open (do not open System Settings)  --no-selftest  --no-bonjour  --no-setup (install only)
# Signing: SIGN_IDENTITY="Apple Development: Name (ID)" signs a build made here; without it the first Apple Development
# identity in the keychain is used; with none, the build is ad-hoc signed and the Accessibility approval must be
# redone after every update (a certificate signature keeps it).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
binary="${SIGNED_BINARY:-}"
# shellcheck source-path=SCRIPTDIR source=../scripts/load-env.sh
. "$here/../scripts/load-env.sh"
port="${PORT:-${GREENFIELD_PORT:-}}"   # empty: the build's own default, asked of it after the install
label="${LABEL:-local.greenfield.inserter}"
prefix="${PREFIX:-$HOME/.local/share/greenfield-inserter}"
config="${GREENFIELD_INSERTER_HOME:-$HOME/.config/greenfield-inserter}"
setup_args=()
extra_serve=""
run_setup=1
timeout=600

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) binary="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --home) config="$2"; shift 2 ;;
        --timeout) timeout="$2"; shift 2 ;;
        --no-open) setup_args+=(--no-open); shift ;;
        --no-selftest) setup_args+=(--no-selftest); shift ;;
        --no-bonjour) extra_serve="$extra_serve --no-bonjour"; shift ;;
        --no-setup) run_setup=0; shift ;;
        -h|--help) sed -n '2,19p' "$here/install.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

[ "$(uname)" = Darwin ] || { echo "Greenfield's Mac side runs on macOS only." >&2; exit 1; }

# Find a signed binary: the one given, or one shipped next to this script, or build one here.
if [ -z "$binary" ] && [ -x "$here/greenfield-inserter" ] && codesign --verify --strict "$here/greenfield-inserter" 2>/dev/null; then
    binary="$here/greenfield-inserter"
fi
if [ -n "$binary" ]; then
    [ -x "$binary" ] || { echo "$binary is not an executable file." >&2; exit 1; }
    codesign --verify --strict "$binary" 2>/dev/null || { echo "$binary has no valid signature; refusing to install it." >&2; exit 1; }
    echo "Installing the signed build $binary"
    export SIGNED_BINARY="$binary"
else
    command -v swift >/dev/null || { echo "No signed build was given and swift is not installed here. Pass --binary FILE, or install the Xcode command-line tools." >&2; exit 1; }
    if [ -z "${SIGN_IDENTITY:-}" ]; then
        SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    fi
    if [ -n "${SIGN_IDENTITY:-}" ]; then
        echo "Building and signing with: $SIGN_IDENTITY"
        export SIGN_IDENTITY
    else
        echo "No Apple Development certificate found: building with an ad-hoc signature."
        echo "(It works, but macOS will ask for the Accessibility approval again after every update.)"
        unset SIGN_IDENTITY
    fi
fi

export LABEL="$label" PORT="$port" PREFIX="$prefix" GREENFIELD_INSERTER_HOME="$config" NO_LINK=1 EXTRA_SERVE_ARGS="${extra_serve# }"
scripts/agent.sh install
[ -n "$port" ] || port="$("$prefix/greenfield-inserter" port)"

if [ "$run_setup" = 1 ]; then
    echo
    exec "$prefix/greenfield-inserter" setup --port "$port" --label "$label" --install-to "$prefix/greenfield-inserter" \
        --timeout "$timeout" ${setup_args[@]+"${setup_args[@]}"}
fi
