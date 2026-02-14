#!/usr/bin/env bash
set -euo pipefail

# Self-contained installer for zigsper.
# Ships in the dist tarball alongside the binary and shared libs.
#
# Usage:
#   ./install.sh              Full interactive setup (download models, permissions, systemd)
#   ./install.sh pw-detect    Detect best PipeWire microphone channel (delegates to zigsper --pw-detect)
#   ./install.sh setup-dev DIR  Developer mode: permissions + pw-detect + systemd (called by run.ts)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WHISPER_MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
VAD_MODEL_NAME="ggml-silero-v5.1.2.bin"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_NAME}"
VAD_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${VAD_MODEL_NAME}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    printf '%s [Y/n] ' "$prompt"
    read -r answer
    case "${answer,,}" in
        ""|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

# ─── Permissions ──────────────────────────────────────────────────────────────

check_permissions() {
    # Check input group membership
    if ! id -nG | grep -qw input; then
        echo ""
        echo "=== Permissions Setup ==="
        echo "The 'input' group is needed for keyboard grab and text injection."
        if confirm "Add current user to 'input' group? (requires sudo)"; then
            sudo usermod -aG input "$USER"
            echo "Added to 'input' group. You may need to log out and back in."
        fi
    fi

    # Check /dev/uinput access
    local uinput_rule='/etc/udev/rules.d/99-uinput.rules'
    if [ ! -f "$uinput_rule" ]; then
        echo ""
        echo "Setting up /dev/uinput access..."
        if confirm "Install udev rule for /dev/uinput? (requires sudo)"; then
            echo 'KERNEL=="uinput", MODE="0660", GROUP="input"' | sudo tee "$uinput_rule" >/dev/null
            sudo udevadm control --reload-rules || true
            sudo udevadm trigger /dev/uinput || true
            echo "udev rule installed."
        fi
    fi
}

# ─── Model Download ──────────────────────────────────────────────────────────

download_models() {
    local model_dir="$1"
    mkdir -p "$model_dir"
    local missing=()

    [ -f "$model_dir/$WHISPER_MODEL_NAME" ] || missing+=("Whisper model (large-v3-turbo-q5_0, ~574 MB)")
    [ -f "$model_dir/$VAD_MODEL_NAME" ] || missing+=("VAD model (silero-v5.1.2, ~2 MB)")

    if [ ${#missing[@]} -eq 0 ]; then
        echo "Models already present."
        return
    fi

    echo "Missing models:"
    for m in "${missing[@]}"; do echo "  - $m"; done

    if ! confirm "Download now?"; then
        die "Models required. Download manually into $model_dir/"
    fi

    require_cmd curl "Install curl to download models."

    if [ ! -f "$model_dir/$WHISPER_MODEL_NAME" ]; then
        echo "Downloading Whisper model..."
        curl -L --progress-bar -o "$model_dir/$WHISPER_MODEL_NAME" "$WHISPER_MODEL_URL"
    fi
    if [ ! -f "$model_dir/$VAD_MODEL_NAME" ]; then
        echo "Downloading VAD model..."
        curl -L --progress-bar -o "$model_dir/$VAD_MODEL_NAME" "$VAD_MODEL_URL"
    fi

    echo "Models downloaded."
}

# ─── PipeWire Channel Detection ──────────────────────────────────────────────

pw_detect() {
    local target="${1:-}"
    local detect_args=(--pw-detect)
    [ -n "$target" ] && detect_args+=(--pw-target "$target")
    "$SCRIPT_DIR/zigsper" "${detect_args[@]}"
}

# ─── Systemd Service ─────────────────────────────────────────────────────────

install_service() {
    local work_dir="$1"
    local binary="$2"
    local channel="$3"
    local target="${4:-}"

    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"

    local exec_start="$binary --trigger capslock --pw-channel $channel"
    [ -n "$target" ] && exec_start="$exec_start --pw-target $target"

    cat > "$service_dir/zigsper.service" <<EOF
[Unit]
Description=Zigsper push-to-talk dictation

[Service]
Type=simple
WorkingDirectory=$work_dir
ExecStart=$exec_start
Restart=always
RestartSec=5
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable zigsper.service 2>/dev/null || true
    echo "zigsper.service installed."
}

# ─── Subcommands ──────────────────────────────────────────────────────────────

cmd_install() {
    echo "=== Zigsper Installer ==="
    echo ""

    # Verify we're in a dist directory with the binary
    [ -f "$SCRIPT_DIR/zigsper" ] || die "zigsper binary not found in $SCRIPT_DIR"

    # Check runtime deps
    require_cmd nvidia-smi "NVIDIA driver required for CUDA inference."
    command -v pw-cli >/dev/null 2>&1 || echo "WARNING: pw-cli not found. PipeWire may not be installed."

    # Permissions
    check_permissions

    # Download models
    download_models "$SCRIPT_DIR/models"

    # Audio detection
    local channel="FL"
    echo ""
    echo "=== Audio Configuration ==="
    if confirm "Run microphone channel detection? (No = use default FL)"; then
        local detect_output
        detect_output=$(pw_detect)
        echo "$detect_output"
        channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
        [ -z "$channel" ] && channel="FL"
    else
        echo "Using default channel: FL"
    fi

    # Systemd service
    install_service "$SCRIPT_DIR" "$SCRIPT_DIR/zigsper" "$channel"

    echo ""
    if confirm "Start the dictation service now?"; then
        systemctl --user restart zigsper.service
        echo "Service started. Check status with:"
        echo "  systemctl --user status zigsper.service"
    else
        echo ""
        echo "Start manually with:"
        echo "  systemctl --user start zigsper.service"
    fi
}

cmd_setup_dev() {
    # Called from run.ts setup — binary is in the source tree
    local project_dir="${1:?Usage: install.sh setup-dev PROJECT_DIR}"

    check_permissions

    local channel="FL"
    echo ""
    echo "=== Audio Configuration ==="
    if confirm "Run microphone channel detection? (No = use default FL)"; then
        local detect_output
        detect_output=$(pw_detect)
        echo "$detect_output"
        channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
        [ -z "$channel" ] && channel="FL"
    else
        echo "Using default channel: FL"
    fi

    install_service "$project_dir" "$project_dir/dist/bin/zigsper" "$channel"

    echo ""
    echo "zigsper.service ready"
    if confirm "Start the dictation service now?"; then
        systemctl --user restart zigsper.service
        echo "Service started. Check status with:"
        echo "  systemctl --user status zigsper.service"
    else
        echo ""
        echo "Start manually with:"
        echo "  systemctl --user start zigsper.service"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-install}" in
    install)    cmd_install ;;
    setup-dev)  shift; cmd_setup_dev "$@" ;;
    pw-detect)  shift; pw_detect "$@" ;;
    *)          die "Unknown command: $1. Usage: install.sh [install|pw-detect|setup-dev]" ;;
esac
