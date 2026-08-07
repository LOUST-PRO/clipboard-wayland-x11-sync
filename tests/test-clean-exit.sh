#!/usr/bin/env bash
# test-clean-exit.sh — verify the script exits cleanly on signal
#
# Strategy:
#   1. Spawn the script in background with all preconditions met (mock
#      WAYLAND_DISPLAY + DISPLAY).
#   2. Wait briefly for it to settle.
#   3. Send SIGTERM, verify exit within 2 seconds.
#   4. Verify no leftover state files.

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/clipboard-wayland-x11-sync"

# Skip if real Wayland/X11 tools are missing (we'd need to mock them
# which complicates the test). The prerequisites test already covers
# the missing-tool path.
for cmd in wl-paste wl-copy xclip perl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "SKIP: missing required tool '$cmd' (install wl-clipboard, xclip, perl)"
        exit 0
    fi
done

# Mock WAYLAND_DISPLAY + DISPLAY, run in background
WAYLAND_DISPLAY="wayland-test" DISPLAY=":99" \
    "$SCRIPT" &
SCRIPT_PID=$!
sleep 1

if ! kill -0 "$SCRIPT_PID" 2>/dev/null; then
    echo "FAIL: script exited unexpectedly (check preflight)"
    wait "$SCRIPT_PID" 2>/dev/null || true
    exit 1
fi

echo "Script running with PID $SCRIPT_PID, sending SIGTERM..."
kill -TERM "$SCRIPT_PID"

# Wait up to 5 seconds for clean exit
for i in $(seq 1 50); do
    if ! kill -0 "$SCRIPT_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if kill -0 "$SCRIPT_PID" 2>/dev/null; then
    echo "FAIL: script did not exit within 5s of SIGTERM"
    kill -9 "$SCRIPT_PID" 2>/dev/null
    exit 1
fi

wait "$SCRIPT_PID" 2>/dev/null
echo "PASS: clean exit on SIGTERM"

# Verify no leftover state files
if [ -d "$STATE_DIR" ]; then
    leftover=$(find "$STATE_DIR" -type f 2>/dev/null | wc -l)
    if [ "$leftover" -gt 0 ]; then
        echo "FAIL: $leftover state files left in $STATE_DIR"
        find "$STATE_DIR" -type f
        exit 1
    fi
fi

echo "PASS: clean-exit test suite complete"
exit 0
