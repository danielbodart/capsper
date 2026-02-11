#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMUL_DIR="$SCRIPT_DIR/SimulStreaming"
MODEL_NAME="large-v3-turbo"
MODEL_FILE="$SIMUL_DIR/$MODEL_NAME.pt"

# --- Git submodule ---
if [[ ! -f "$SIMUL_DIR/simulstreaming_whisper_server.py" ]]; then
    echo "Initialising SimulStreaming submodule..."
    git -C "$SCRIPT_DIR" submodule update --init --recursive
fi

# --- Python via uv ---
if ! command -v uv >/dev/null 2>&1; then
    echo "ERROR: uv is required but not installed." >&2
    echo "Install with: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    exit 1
fi

echo "Syncing python and dependencies via uv..."
uv sync --project "$SCRIPT_DIR"

# --- System dependencies ---
missing=()
command -v arecord >/dev/null 2>&1 || missing+=("alsa-utils")
command -v nc      >/dev/null 2>&1 || missing+=("ncat")

# Backend-specific deps (detect like whisper.sh does)
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    command -v evtest  >/dev/null 2>&1 || missing+=("evtest")
    command -v ydotool >/dev/null 2>&1 || missing+=("ydotool")
    command -v ydotoold >/dev/null 2>&1 || missing+=("ydotoold")
    command -v keyd.rvaiya >/dev/null 2>&1 || command -v keyd >/dev/null 2>&1 || missing+=("keyd")
else
    command -v xinput  >/dev/null 2>&1 || missing+=("xinput")
    command -v xdotool >/dev/null 2>&1 || missing+=("xdotool")
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Installing missing system packages: ${missing[*]}"
    sudo apt install -y "${missing[@]}"
fi

# --- Whisper model ---
if [[ ! -f "$MODEL_FILE" ]]; then
    echo "Downloading $MODEL_NAME model (~800 MB)..."
    uv run --project "$SCRIPT_DIR" python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$SIMUL_DIR', 'simulstreaming', 'whisper', 'simul_whisper'))
from whisper import load_model
load_model('$MODEL_NAME', download_root='$SIMUL_DIR')
print('Model downloaded to $MODEL_FILE')
"
fi

# --- Wayland: keyd + uinput setup ---
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    echo "Setting up keyd (Caps Lock → F24) and uinput permissions..."
    sudo "$SCRIPT_DIR/setup-keyd.sh"
fi

# --- Wayland: ydotoold user service ---
if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    if ! systemctl --user is-active --quiet ydotoold 2>/dev/null; then
        echo "Setting up ydotoold user service..."
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/ydotoold.service" <<'EOF'
[Unit]
Description=ydotool daemon
Documentation=https://github.com/ReimuNotMoe/ydotool

[Service]
ExecStart=/usr/bin/ydotoold
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now ydotoold
        echo "ydotoold service started"
    fi
fi

# --- whisper.service user service ---
echo "Installing whisper systemd user service..."
mkdir -p "$HOME/.config/systemd/user"

SERVICE_ENVS="Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    SERVICE_AFTER="After=ydotoold.service"
    SERVICE_REQUIRES="Requires=ydotoold.service"
    SERVICE_ENVS="$SERVICE_ENVS
Environment=XDG_SESSION_TYPE=wayland
Environment=WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
else
    SERVICE_AFTER=""
    SERVICE_REQUIRES=""
    SERVICE_ENVS="$SERVICE_ENVS
Environment=XDG_SESSION_TYPE=x11
Environment=DISPLAY=${DISPLAY:-:0}"
fi

cat > "$HOME/.config/systemd/user/whisper.service" <<EOF
[Unit]
Description=Whisper push-to-talk dictation
$SERVICE_AFTER
$SERVICE_REQUIRES

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/whisper.sh
Restart=always
RestartSec=5
$SERVICE_ENVS

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable whisper.service
echo "whisper.service installed and enabled"

echo ""
echo "Setup complete! Start dictation with:"
echo "  systemctl --user start whisper"
