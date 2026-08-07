#!/usr/bin/env bash
# install.sh — install clipboard-wayland-x11-sync for a single user
#
# Installs:
#   - bin/clipboard-wayland-x11-sync.sh     → ~/.local/bin/
#   - bin/clipboard-w2x-wrapper.sh          → ~/.local/bin/
#   - systemd/clipboard-wayland-x11-sync.service → ~/.config/systemd/user/
#   - enables + starts the user service
#
# Idempotent. Re-running won't duplicate or break anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

echo "==> Installing clipboard-wayland-x11-sync to $PREFIX"

# 1. Copy scripts
install -d "$PREFIX/bin"
install -m 0755 "$SCRIPT_DIR/bin/clipboard-wayland-x11-sync.sh" "$PREFIX/bin/"
install -m 0755 "$SCRIPT_DIR/bin/clipboard-w2x-wrapper.sh" "$PREFIX/bin/"

# 2. Install systemd user service
install -d "$SYSTEMD_USER_DIR"
install -m 0644 "$SCRIPT_DIR/systemd/clipboard-wayland-x11-sync.service" "$SYSTEMD_USER_DIR/"

# 3. Reload + enable
systemctl --user daemon-reload
systemctl --user enable clipboard-wayland-x11-sync.service
systemctl --user restart clipboard-wayland-x11-sync.service

echo ""
echo "==> Service status:"
systemctl --user status clipboard-wayland-x11-sync.service --no-pager || true
echo ""
echo "==> Logs (last 20 lines, follow with: journalctl --user -u clipboard-wayland-x11-sync -f):"
journalctl --user -u clipboard-wayland-x11-sync -n 20 --no-pager 2>/dev/null || echo "(no logs yet)"
echo ""
echo "To stop: systemctl --user stop clipboard-wayland-x11-sync"
