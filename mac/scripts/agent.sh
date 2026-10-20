#!/bin/bash
# Installs greenfield-inserter as a per-user launchd agent: starts at login, restarts if it
# crashes, and logs to a file that never contains inserted text.
#
#   scripts/agent.sh install     build, copy the binary to a stable path, load the agent
#   scripts/agent.sh uninstall   unload and remove the agent and the installed binary
#   scripts/agent.sh status      show whether launchd is running it
#   scripts/agent.sh logs        tail the log
#
# Overrides: LABEL, PREFIX, PORT, GREENFIELD_INSERTER_HOME (mainly for testing), and
# SIGN_IDENTITY - a code-signing identity name to sign with instead of the default ad-hoc signature.
# An ad-hoc signature changes with every build, which invalidates the Accessibility approval; a
# certificate signature keeps the same identity across rebuilds. SIGNED_BINARY=/path installs that
# already-signed binary as it is (no build, no re-signing): sign once where the certificate lives, then
# install the same file on every Mac.
set -euo pipefail

cd "$(dirname "$0")/.."
LABEL="${LABEL:-local.greenfield.inserter}"
PREFIX="${PREFIX:-$HOME/.local/share/greenfield-inserter}"
PORT="${PORT:-47821}"
CONFIG_HOME="${GREENFIELD_INSERTER_HOME:-$HOME/.config/greenfield-inserter}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$CONFIG_HOME/inserter.log"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
install)
    if [ -z "${SIGNED_BINARY:-}" ]; then swift build -c release >&2; fi
    mkdir -p "$PREFIX" "$CONFIG_HOME" "$HOME/Library/LaunchAgents"
    chmod 700 "$CONFIG_HOME"
    # launchd needs a stable path, and macOS ties the Accessibility grant to that binary.
    if [ -n "${SIGNED_BINARY:-}" ]; then
        cp "$SIGNED_BINARY" "$PREFIX/greenfield-inserter.new"
        codesign --verify "$PREFIX/greenfield-inserter.new" >&2
    else
        cp .build/release/greenfield-inserter "$PREFIX/greenfield-inserter.new"
        codesign --force --sign "${SIGN_IDENTITY:--}" --identifier greenfield-inserter "$PREFIX/greenfield-inserter.new"
    fi
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    mv "$PREFIX/greenfield-inserter.new" "$PREFIX/greenfield-inserter"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PREFIX/greenfield-inserter</string>
        <string>serve</string>
        <string>--port</string><string>$PORT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GREENFIELD_INSERTER_HOME</key><string>$CONFIG_HOME</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>$CONFIG_HOME/launchd-stderr.log</string>
</dict>
</plist>
PLISTEOF
    chmod 644 "$PLIST"
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "installed $LABEL (binary $PREFIX/greenfield-inserter, log $LOG)"
    ;;
uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$PREFIX/greenfield-inserter"
    rmdir "$PREFIX" 2>/dev/null || true
    echo "removed $LABEL (config and key in $CONFIG_HOME left in place)"
    ;;
status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state =|pid =|last exit|runs =" || echo "not loaded"
    ;;
logs)
    tail -n "${LINES:-50}" -f "$LOG"
    ;;
*)
    echo "usage: $0 install|uninstall|status|logs" >&2
    exit 2
    ;;
esac
