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

# --- Python via mise ---
if ! command -v mise >/dev/null 2>&1; then
    echo "ERROR: mise is required but not installed." >&2
    echo "Install from https://mise.jdx.dev" >&2
    exit 1
fi

echo "Ensuring python is installed via mise..."
mise install

# --- Python dependencies ---
echo "Installing python dependencies..."
mise exec -- pip install -q -r "$SIMUL_DIR/requirements_whisper.txt"

# --- System dependencies ---
missing=()
command -v xinput  >/dev/null 2>&1 || missing+=("xinput (xinput)")
command -v xdotool >/dev/null 2>&1 || missing+=("xdotool")
command -v arecord >/dev/null 2>&1 || missing+=("arecord (alsa-utils)")
command -v nc      >/dev/null 2>&1 || missing+=("nc (nmap-ncat or ncat)")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing system packages: ${missing[*]}"
    echo "Install them with your package manager, e.g.:"
    echo "  sudo apt install xinput xdotool alsa-utils ncat"
    exit 1
fi

# --- Whisper model ---
if [[ ! -f "$MODEL_FILE" ]]; then
    echo "Downloading $MODEL_NAME model (~800 MB)..."
    mise exec -- python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$SIMUL_DIR', 'simulstreaming', 'whisper', 'simul_whisper'))
from whisper import load_model
load_model('$MODEL_NAME', download_root='$SIMUL_DIR')
print('Model downloaded to $MODEL_FILE')
"
fi

echo ""
echo "Setup complete. Run with:"
echo "  ./whisper.sh"
