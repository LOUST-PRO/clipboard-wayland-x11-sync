# Design decisions — clipboard-wayland-x11-sync

This document explains the non-obvious choices in the script.
If you're reviewing the code and asking "why this and not that",
this is the first place to look.

## 1. Two paths, not one (event-driven + polling)

**Decision**: Wayland→X11 uses `wl-paste --watch` (event-driven),
X11→Wayland uses `xclip` polling at 600ms.

**Rationale**: Wayland has `wl-paste --watch` for event-driven
clipboard change notifications. X11 has **no equivalent primitive**
without `xsel`, which isn't installed everywhere. We could
require `xsel` and make it pure event-driven, but that's an
extra dependency for marginal benefit on the X11 side.

Polling at 600ms costs <0.5% CPU (measured) and the perceived
latency is fine — half a second is unnoticeable for a paste.

## 2. Binary filter is non-negotiable

**Decision**: any clipboard content with NUL bytes, PNG/JPEG/GIF/PDF
headers, or invalid UTF-8 is **rejected** before re-pushing.

**Rationale**: an image clipboard (e.g. screenshot copied from
Flameshot) loops back as binary bytes that:
- Trigger the polling path repeatedly (no identical-write detection
  because the polled bytes differ frame-to-frame for animation).
- Bloat the Wayland clipboard with content the user didn't ask to sync.
- Cause `wl-copy` to misbehave on the receiving side (paste-back
  attempts show as garbled or wrong).

**Observed pathology (2026-08-05)**: with a 616x713 PNG in X11
clipboard, the unfiltered polling version consumed **15.3% CPU**.
With the filter: **~0.4% CPU**. Three orders of magnitude.

The filter is the same on both paths so behavior is symmetric.

## 3. Loop guard via prev-hash tracking

**Decision**: each direction tracks its last-written content in
a state file. If the new content matches, skip the push.

**Rationale**: even with binary filter, a 1KB text re-write from
`wl-copy` would still bounce to X11, then poll back to Wayland
(unchanged), then `--watch` would not fire (no change), then the
poll would see same content, then... ok, mostly fine, but **on the
polling side**: any momentary X11→Wayland write followed by an
X11-side re-emit (e.g. X11 clipboard manager rewriting with
metadata) would loop.

The prev-hash check kills all those paths with one O(1) string
compare. The state file lives in `$XDG_RUNTIME_DIR` (cleared on
session logout, no persistence concerns).

## 4. State lives in `$XDG_RUNTIME_DIR`, not `/tmp`

**Decision**: PID + prev-hash files go to
`$XDG_RUNTIME_DIR/clipboard-wayland-x11-sync/`, falling back to
`/tmp/clipboard-wayland-x11-sync/` if the env var is unset.

**Rationale**: `$XDG_RUNTIME_DIR` (default `/run/user/$UID/`) is
the canonical place for per-user runtime state per the XDG Base
Directory spec. It's:
- Auto-created by systemd-logind on session start.
- Auto-cleaned on session logout (no stale state).
- Mode 0700 (only the owning user can read).

`/tmp` works as fallback but persists across sessions and is
world-readable — bad for state with potential clipboard content
in it.

## 5. Perl filter, not Python or pure bash

**Decision**: the binary filter is a single perl one-liner.

**Rationale**:
- **Perl's `utf8::decode` is reliable**: it sets the UTF-8 flag
  and returns false on invalid bytes. `utf8::valid` alone lies
  about raw bytes without the flag (a known perl footgun).
- **Perl's `binmode ":raw"` is explicit**: forces byte-level
  reads, avoiding any locale-driven text interpretation.
- **Python would work but adds a runtime dependency**.
- **Pure bash can't do it**: bash strips NUL bytes during
  `$()` command substitution. The original 2026-08-04 bug.

## 6. `printf '%s' "$curr" | perl` instead of heredoc

**Decision**: pipe content via `printf | perl -e ...` instead of
embedding the perl script in a heredoc inside the bash loop.

**Rationale**: heredocs with literal binary content (if any slipped
through) get mangled by bash's interpretation. Piping via `printf`
with `%-s` (no trailing newline) preserves bytes exactly.

The `wl-paste --watch` path uses heredoc (`<<<`) because there's
no buffer issue there (single event at a time).

## 7. systemd user service, NOT system service

**Decision**: the service unit has `WantedBy=graphical-session.target`
and uses `~` (home-dir expansion) for the binary path.

**Rationale**:
- `WAYLAND_DISPLAY` and `DISPLAY` env vars are per-session, not
  global. A system service started at boot wouldn't have them.
- User services auto-stop on logout, auto-start on next login.
- No root needed → no privilege escalation risk.

`MemoryMax=16M` and `MemoryHigh=12M` are mandatory. Polling loops
can leak; capping memory is the structural guard. If we observe
>12 MiB resident, it's a bug we want to detect, not absorb.

## 8. `X2W_POLL_MS` instead of fixed sleep

**Decision**: poll cadence is configurable via env var
(default 600ms). Converted to seconds with millisecond precision
via awk.

**Rationale**:
- 600ms is the sweet spot for desktop use.
- Power users might prefer 1000ms (lower CPU).
- CI / scripted testing might prefer 100ms (faster convergence).
- Hard-coded 0.6 wouldn't allow testing the loop-guard logic with
  arbitrary cadences.

## 9. Empty content = skip

**Decision**: if `wl-paste` produces empty output, exit 0 silently
without filtering or pushing.

**Rationale**: wl-paste fires on `selection-clear` events in some
versions, which produce empty content. Without this guard, the
filter runs on an empty string (always passes), then `xclip -i`
writes empty content to X11, which may clear the clipboard.
Empty clipboard = frustrated user.

## 10. No systemd D-Bus activation

**Decision**: the service runs continuously, not on-demand via D-Bus.

**Rationale**: clipboard sync is not a per-request operation. It's
ambient — you want it running as long as the session is alive.
D-Bus activation would add complexity for no benefit. A simple
Type=simple service with `Wants=graphical-session.target` is the
right primitive.

## What this script is NOT

(Repeated from README, but worth emphasizing in design docs.)

- Not a clipboard **manager** (no history, no UI).
- Not for **image** clipboard sync. Binary content is intentionally rejected.
- Not for **primary** selection (middle-click paste). Only `CLIPBOARD` selection.
- Not for **Wayland-only** or **X11-only** sessions — the script exits
  silently if either `WAYLAND_DISPLAY` or `DISPLAY` is unset.

## Why not use `xwayland-clipboard-sync` (Debian's existing tool)?

It exists. We tested it. Found two issues that this script solves:

1. **No binary filter**: it happily syncs a 600KB PNG, with the
   ~15% CPU pathology we observed.
2. **No loop guard**: identical content re-writes bounce back and forth.

If your use case is "occasional text copy between X11 and Wayland,
no image workflow", the Debian tool is fine. If you copy images
frequently (screenshot tools, image editors), this script saves
you from the CPU drain.
