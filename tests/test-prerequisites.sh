#!/usr/bin/env bash
# test-prerequisites.sh — verify preflight checks exit cleanly
#
# Strategy:
#   1. Run the script with WAYLAND_DISPLAY unset → should exit 0 silently
#   2. Run with DISPLAY unset → should exit 0 silently
#   3. Verify no PID/state files are created when exiting early.

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/clipboard-wayland-x11-sync"

# Test 1: WAYLAND_DISPLAY unset
echo "--- Test: WAYLAND_DISPLAY unset ---"
WAYLAND_DISPLAY="" DISPLAY=":0" \
    timeout 5 "$SCRIPT" 2>&1 | head -3
if [ $? -eq 0 ]; then
    echo "PASS: exited cleanly when WAYLAND_DISPLAY unset"
else
    echo "FAIL: non-zero exit when WAYLAND_DISPLAY unset"
    exit 1
fi

# Test 2: DISPLAY unset
echo "--- Test: DISPLAY unset ---"
WAYLAND_DISPLAY="wayland-0" DISPLAY="" \
    timeout 5 "$SCRIPT" 2>&1 | head -3
if [ $? -eq 0 ]; then
    echo "PASS: exited cleanly when DISPLAY unset"
else
    echo "FAIL: non-zero exit when DISPLAY unset"
    exit 1
fi

# Verify no state leaked
if [ -f "$STATE_DIR/w2x.pid" ] || [ -f "$STATE_DIR/x2w.pid" ]; then
    echo "FAIL: pid files leaked into state dir"
    ls -la "$STATE_DIR"
    exit 1
fi

echo "PASS: prerequisites test suite complete"
exit 0
