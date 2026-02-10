#!/bin/bash
set -euo pipefail

# System-level setup for whisper.sh push-to-talk on Wayland
# - keyd: remap Caps Lock to F24
# - uinput: allow input group to use ydotool for typing
# Requires root

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    echo "  sudo ./setup-keyd.sh"
    exit 1
fi

# --- keyd: Caps Lock → F24 ---

# keyd binary may be named keyd or keyd.rvaiya depending on distro
KEYD_BIN=""
for name in keyd keyd.rvaiya; do
    if command -v "$name" >/dev/null 2>&1; then
        KEYD_BIN="$name"
        break
    fi
done

if [[ -z "$KEYD_BIN" ]]; then
    echo "keyd is not installed. Install it first:"
    echo "  sudo apt install keyd     # Debian/Ubuntu"
    echo "  sudo pacman -S keyd       # Arch"
    echo "  https://github.com/rvaiya/keyd"
    exit 1
fi

mkdir -p /etc/keyd

cat > /etc/keyd/default.conf << 'EOF'
[ids]
*

[main]
capslock = f24
EOF

echo "Wrote /etc/keyd/default.conf (capslock → f24)"

if systemctl is-active --quiet keyd; then
    "$KEYD_BIN" reload
    echo "keyd reloaded."
else
    systemctl enable --now keyd
    echo "keyd enabled and started."
fi

# --- uinput: allow input group access (needed by ydotool) ---

UDEV_RULE="/etc/udev/rules.d/99-uinput.rules"
if [[ ! -f "$UDEV_RULE" ]] || ! grep -q 'uinput' "$UDEV_RULE" 2>/dev/null; then
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' > "$UDEV_RULE"
    udevadm control --reload-rules
    udevadm trigger /dev/uinput
    echo "Created udev rule for /dev/uinput (group=input, mode=0660)"
else
    echo "uinput udev rule already exists."
fi

# --- Check user is in input group ---

SUDO_USER="${SUDO_USER:-}"
if [[ -n "$SUDO_USER" ]] && ! id -nG "$SUDO_USER" | grep -qw input; then
    usermod -aG input "$SUDO_USER"
    echo "Added $SUDO_USER to input group (log out and back in to take effect)"
fi

echo ""
echo "Done. Test with:"
echo "  evtest         # should show KEY_F24 when pressing Caps Lock"
echo "  ydotool type test  # should type 'test' into focused window"
