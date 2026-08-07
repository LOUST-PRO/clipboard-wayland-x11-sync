# clipboard-wayland-x11-sync

**Bidirectional text clipboard sync between Wayland and X11 — designed for mixed desktop environments (Wayland native + XWayland apps).**

When you run a native Wayland desktop session but use apps that still talk
to X11 (Chromium/Chrome, sometimes Firefox in distrobox, JetBrains
Toolbox, etc.), copy-paste breaks: an app on X11 copies, but `Mod+V` in
a native Wayland app pastes nothing because the X11 clipboard isn't
mirrored to the Wayland one (and vice-versa).

This daemon keeps both clipboards in sync for **text only**, with two
guards:

1. **Binary content filter** — image/screenshot/archive clipboards are
   never synced (causes CPU pathology + wrong-content pastes).
2. **Loop guard** — same-content re-writes don't bounce back and forth.

```text
XWayland app (Chromium)        Native Wayland app (your terminal)
       │                                  ▲
       │ xclip                            │ wl-paste
       ▼                                  │
  ┌─────────────┐ poll 600ms    --watch  ┌─────────────┐
  │  X11 buffer │◄───────────────────────│ Wayland buf │
  └─────────────┘                        └─────────────┘
        ▲                                     │
        │ xclip                               │ wl-copy
        └─────────clipboard-wayland-x11-sync.sh
              (event-driven w2x + polling x2w)
```

## Quick start

```bash
# 1. Install (user-level, no root required)
./install.sh

# 2. Verify it's running
systemctl --user status clipboard-wayland-x11-sync

# 3. Test it: copy in an X11 app, paste in a Wayland app (and vice-versa)
```

## Prerequisites

| Tool | Package (Debian/Ubuntu) |
|------|-------------------------|
| `wl-paste` / `wl-copy` | `wl-clipboard` |
| `xclip` | `xclip` |
| `perl` | `perl-base` (default) |
| `logger` | `bsdmainutils` or `util-linux` (default) |

## How it works

Two independent paths, each guarded against binary content and feedback
loops:

### Wayland → X11 (event-driven, 0% CPU when idle)

`wl-paste --watch` invokes `clipboard-w2x-wrapper.sh` on every Wayland
clipboard change. The wrapper:

1. Reads the new content.
2. Runs a perl filter that rejects NUL bytes, PNG/JPEG/GIF/PDF signatures,
   and invalid UTF-8.
3. Compares against `$W2X_PREV_FILE`; if identical, skips the write.
4. Pushes to X11 via `xclip -selection clipboard -i`.

This path uses **0% CPU when idle** — the OS only wakes it on actual
clipboard events.

### X11 → Wayland (polling, default 600ms)

X11 has no event-driven primitive without `xsel` (not always installed),
so this path polls `xclip -selection clipboard -t text/plain -o` every
`$X2W_POLL_MS` (default 600ms). On change:

1. Run the same perl binary/UTF-8 filter.
2. Push to Wayland via `wl-copy`.
3. Track previous content in `$X2W_PREV_FILE` to skip identical writes.

**Why 600ms, not 400ms?** The polling cadence is a trade-off:
- Faster = lower perceived latency on paste.
- Slower = lower CPU + less chance of feedback loops under load.

600ms is the sweet spot: paste-within-half-second feels instant, and
the polling CPU stays negligible.

### Binary filter

The perl filter is the same on both paths. It rejects in one pass:

| Signal | Why rejected |
|--------|--------------|
| NUL byte (`\0`) | Standard binary marker |
| PNG header (`\x89PNG\r\n\x1a\n`) | Screenshots, image clipboard |
| JPEG header (`\xff\xd8\xff`) | Same |
| GIF header (`GIF...`) | Same |
| PDF header (`%PDF-`) | Document clipboard |
| Invalid UTF-8 | Anything that isn't text |

Why reject binary? Because:

- **CPU pathology**: pushing a 600KB PNG back and forth every 600ms
  = ~15% CPU on the polling path. Observed and measured.
- **Wrong-content paste**: a copy-image operation will land on the
  Wayland side as base64-encoded bytes (sometimes) or as a raw
  image-pointer reference that wl-copy can't reproduce.

The filter lives in [`docs/binary-filter.md`](docs/binary-filter.md)
with full perl code + alternative approaches considered.

## Configuration

| Env var | Default | Notes |
|---------|---------|-------|
| `CLIPBOARD_SYNC_TAG` | `clipboard-sync` | Logger tag (visible in `journalctl`) |
| `CLIPBOARD_W2X_WRAPPER` | `<script_dir>/clipboard-w2x-wrapper.sh` | Path to w2x helper |
| `CLIPBOARD_SYNC_STATE_DIR` | `$XDG_RUNTIME_DIR/clipboard-wayland-x11-sync` | Where PID + prev files live |
| `CLIPBOARD_W2X_PREV_FILE` | `$STATE_DIR/w2x.prev` | Loop-guard cache for w2x |
| `CLIPBOARD_X2W_POLL_MS` | `600` | Polling cadence in ms |

## systemd integration

The provided service unit (`clipboard-wayland-x11-sync.service`) is
designed to run as a **user service** under `graphical-session.target`,
NOT as a system service. This is critical:

- User services have access to the user's `WAYLAND_DISPLAY` and
  `DISPLAY` env vars.
- They start/stop with the graphical session.
- They don't need root.

Memory is capped at 16 MiB (`MemoryMax=16M`, `MemoryHigh=12M`). The
polling loop has no legitimate reason to grow; if it does, you've
found a leak.

## Comparison with alternatives

| Tool | Mode | Binary filter | Loop guard | Polling |
|------|------|---------------|------------|---------|
| `wl-clipboard-history` | One-way (Wayland store) | n/a | n/a | n/a |
| `clipman` | One-way (primary selection) | partial | yes | 1s |
| `xwayland-clipboard-sync` (Debian) | Bi-directional | NO | NO | event-driven |
| **This script** | Bi-directional (TEXT) | YES (NUL/PNG/JPEG/GIF/PDF/UTF-8) | YES (prev-hash) | 600ms |

## What this script is NOT

- Not a clipboard **manager** (no history, no UI).
- Not for **image** clipboard sync. Binary content is intentionally rejected.
- Not for **primary** selection (middle-click paste). Only `CLIPBOARD`
  selection is synced.
- Not for **Wayland-only** or **X11-only** sessions — the script exits
  silently if either `WAYLAND_DISPLAY` or `DISPLAY` is unset.

## Testing

Three smoke tests live in `tests/`. They use bash's `exec -a` to
spawn fake clipboard tools with custom argv[0] so the script can
find them via `command -v` path resolution:

```bash
cd tests/
./test-prerequisites.sh         ../bin/clipboard-wayland-x11-sync.sh
./test-clean-exit.sh            ../bin/clipboard-wayland-x11-sync.sh
./test-binary-filter.sh         ../bin/clipboard-w2x-wrapper.sh
```

## License

MIT. See [`LICENSE`](LICENSE).

## Author

David Mireles (DavidMireles) — `research@loust.pro`
