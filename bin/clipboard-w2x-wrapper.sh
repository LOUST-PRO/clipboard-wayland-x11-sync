#!/usr/bin/env bash
# clipboard-w2x-wrapper.sh — Wrapper for `wl-paste --watch` to push text to X11
#
# Used by clipboard-wayland-x11-sync.sh as the watch command:
#   wl-paste --watch ./clipboard-w2x-wrapper.sh
#
# wl-clipboard 2.3.0 (Debian forky) doesn't accept --type with --watch
# (--watch takes the next arg as the subcommand), so we filter binary
# content here instead. Stdin is piped DIRECTLY to perl (no bash $(...)
# buffering — bash strips NUL bytes during command substitution).
#
# Loop guard:
#   - wl-paste --watch fires on EVERY Wayland clipboard change event,
#     even when content is identical. Without a guard, this creates a
#     feedback loop: wl-copy → --watch → xclip → poll → wl-copy → ...
#   - Solution: track last-written content via W2X_PREV_FILE. If new
#     content matches, skip the xclip push.
#
# Filter rejects (perl, single pass):
#   1. NUL byte (binary marker)
#   2. Known binary signatures: PNG / JPEG / GIF / PDF
#   3. Invalid UTF-8 (via utf8::decode — sets UTF-8 flag and returns
#      false if bytes aren't valid UTF-8; utf8::valid alone lies about
#      raw bytes without the flag)

set -uo pipefail

STATE_DIR="${CLIPBOARD_SYNC_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/clipboard-wayland-x11-sync}"
mkdir -p "$STATE_DIR"

W2X_PREV_FILE="${CLIPBOARD_W2X_PREV_FILE:-$STATE_DIR/w2x.prev}"

# If input is empty, skip
content="$(cat)"
[ -z "$content" ] && exit 0

# Loop guard: if this exact content was last written by us, skip the
# xclip push. Prevents w2x → x2w → w2x feedback loop when wl-copy
# re-writes the same text.
if [ -f "$W2X_PREV_FILE" ] && [ "$(cat "$W2X_PREV_FILE" 2>/dev/null)" = "$content" ]; then
    exit 0
fi

# Filter via perl: reject binary / invalid UTF-8, emit valid text.
filtered="$(perl -CSDA -e '
    binmode STDIN, ":raw";
    binmode STDOUT, ":raw";

    my $buf = do { local $/; <STDIN> };
    my $len = length($buf);

    # 1) NUL byte present → binary
    if (index($buf, "\0") >= 0) { exit 1; }

    # 2) Known binary signatures (first 8 bytes)
    if ($len >= 3) {
        my $b0 = substr($buf, 0, 1);
        my $b1 = substr($buf, 1, 1);
        my $b2 = substr($buf, 2, 1);

        if ($len >= 8 && substr($buf, 0, 8) eq "\x89PNG\r\n\x1a\n") { exit 1; }
        if ($b0 eq "\xff" && $b1 eq "\xd8" && $b2 eq "\xff") { exit 1; }
        if (substr($buf, 0, 3) eq "GIF") { exit 1; }
        if ($len >= 5 && substr($buf, 0, 5) eq "%PDF-") { exit 1; }
    }

    # 3) UTF-8 validity via utf8::decode
    my $copy = $buf;
    if (!utf8::decode($copy)) { exit 1; }

    print $buf;
' <<< "$content" 2>/dev/null)"

if [ -z "$filtered" ]; then
    exit 0
fi

printf '%s' "$filtered" | xclip -selection clipboard -i 2>/dev/null || exit 0
printf '%s' "$filtered" > "$W2X_PREV_FILE"
