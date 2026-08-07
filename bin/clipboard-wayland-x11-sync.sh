#!/usr/bin/env bash
# clipboard-wayland-x11-sync.sh — Bidirectional Wayland ↔ X11 TEXT clipboard sync
#
# Why: Wayland clipboard managers (e.g. wl-clipboard-history, DMS clipboard)
# listen to Wayland via wl-paste --watch. Apps running on XWayland
# (Chromium / Chrome, sometimes Firefox in distrobox, JetBrains Toolbox,
# etc.) write to X11 clipboard → Mod+V shows nothing in native Wayland apps.
#
# Mirrors the dual-write pattern used for screenshots but for general
# live text clipboard traffic.
#
# Method (mixed event-driven + polling, optimized for low CPU):
#   - Wayland → X11:  wl-paste --watch ./clipboard-w2x-wrapper.sh
#                     (event-driven, 0% CPU when idle; fires only on
#                      Wayland clipboard change; wrapper filters binary
#                      via NUL byte + UTF-8 validity check)
#   - X11 → Wayland:  poll xclip text/plain every X2W_POLL_MS (default 600),
#                     push to wl-copy if changed AND valid text. Polling
#                     is necessary because X11 has no --watch primitive
#                     without xsel (not always installed).
#
# Loop guard:
#   - Wayland → X11: wl-paste --watch only fires on actual clipboard
#     change events; same content re-write doesn't re-trigger.
#   - X11 → Wayland: prev-hash tracking. Identical writes skipped.
#   - Binary clipboards (image/png, archives) NEVER sync — wrapper/
#     poller both detect NUL bytes and exit cleanly.
#
# Pre-checks:
#   - Exits silently if WAYLAND_DISPLAY or DISPLAY are unset (don't break
#     pure X11 sessions or pure Wayland sessions).
#   - Refuses to run if any required tool is missing.

set -uo pipefail

LOG_TAG="${CLIPBOARD_SYNC_TAG:-clipboard-sync}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W2X_WRAPPER="${CLIPBOARD_W2X_WRAPPER:-$SCRIPT_DIR/clipboard-w2x-wrapper.sh}"

STATE_DIR="${CLIPBOARD_SYNC_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/clipboard-wayland-x11-sync}"
mkdir -p "$STATE_DIR"

W2X_PID="$STATE_DIR/w2x.pid"
X2W_PID="$STATE_DIR/x2w.pid"
X2W_PREV_FILE="$STATE_DIR/x2w.prev"

X2W_POLL_MS="${CLIPBOARD_X2W_POLL_MS:-600}"

log() { logger -t "$LOG_TAG" "$@" 2>/dev/null || echo "[$LOG_TAG] $*" >&2; }

cleanup() {
    for pf in "$W2X_PID" "$X2W_PID"; do
        [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null || true
        rm -f "$pf"
    done
    log "stopped"
}

trap cleanup EXIT INT TERM

# Pre-checks
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    log "WAYLAND_DISPLAY unset, nothing to sync"
    exit 0
fi
if [ -z "${DISPLAY:-}" ]; then
    log "DISPLAY unset (no X11), nothing to sync"
    exit 0
fi
for cmd in wl-paste wl-copy xclip perl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "missing required tool: $cmd"
        exit 1
    fi
done
if [ ! -x "$W2X_WRAPPER" ]; then
    log "missing wrapper: $W2X_WRAPPER"
    exit 1
fi

# Convert poll ms to seconds with millisecond granularity (busybox-friendly)
poll_secs=$(awk -v ms="$X2W_POLL_MS" 'BEGIN { printf "%.3f", ms / 1000.0 }')

log "starting sync (w2x=watch+x2w=poll${X2W_POLL_MS}ms, WAYLAND=$WAYLAND_DISPLAY DISPLAY=$DISPLAY)"

# Wayland → X11: event-driven via wl-paste --watch. Wrapper handles
# binary detection and xclip push. 0% CPU when idle.
sync_wayland_to_x11() {
    wl-paste --watch "$W2X_WRAPPER" 2>/dev/null &
    echo $! > "$W2X_PID"
}

# X11 → Wayland: poll. Default 600ms because X11 has no event-driven
# option without xsel. Binary filter prevents the ~15% CPU pathology
# observed when clipboard holds a PNG.
sync_x11_to_wayland() {
    local prev=""
    while true; do
        local curr
        curr="$(xclip -selection clipboard -t text/plain -o 2>/dev/null || true)"
        curr="${curr%$'\n'}"
        if [ -n "$curr" ] && [ "$curr" != "$prev" ]; then
            if printf '%s' "$curr" | perl -CSDA -e '
                binmode STDIN, ":raw";
                my $buf = do { local $/; <STDIN> };
                my $len = length($buf);
                if (index($buf, "\0") >= 0) { exit 1; }
                if ($len >= 3) {
                    my $b0 = substr($buf, 0, 1);
                    my $b1 = substr($buf, 1, 1);
                    my $b2 = substr($buf, 2, 1);
                    if ($len >= 8 && substr($buf, 0, 8) eq "\x89PNG\r\n\x1a\n") { exit 1; }
                    if ($b0 eq "\xff" && $b1 eq "\xd8" && $b2 eq "\xff") { exit 1; }
                    if (substr($buf, 0, 3) eq "GIF") { exit 1; }
                    if ($len >= 5 && substr($buf, 0, 5) eq "%PDF-") { exit 1; }
                }
                my $copy = $buf;
                if (!utf8::decode($copy)) { exit 1; }
            ' 2>/dev/null; then
                printf '%s\n' "$curr" | wl-copy 2>/dev/null || true
                prev="$curr"
                printf '%s' "$curr" > "$X2W_PREV_FILE"
            fi
        fi
        sleep "$poll_secs"
    done &
    echo $! > "$X2W_PID"
}

sync_wayland_to_x11
sync_x11_to_wayland

wait
