#!/usr/bin/env bash
set -euo pipefail

# Self-contained installer for capsper.
# Ships in the dist tarball alongside the binary and shared libs.
#
# In a git checkout (dev mode), installs in-situ pointing at the source tree.
# Otherwise, copies to ~/.local/share/capsper/ for a proper user install.
#
# Usage:
#   ./install.sh              Full interactive setup (download models, permissions, systemd)
#   ./install.sh pw-detect    Detect best PipeWire microphone channel (delegates to capsper --pw-detect)

SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null && pwd)"

WHISPER_MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
VAD_MODEL_NAME="ggml-silero-v5.1.2.bin"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_NAME}"
VAD_MODEL_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/${VAD_MODEL_NAME}"

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"

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

confirm_default_no() {
    local prompt="$1"
    printf '%s [y/N] ' "$prompt"
    read -r answer
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

is_dev_mode() {
    [ -d "$SCRIPT_DIR/../.git" ]
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
        echo ""
        echo "Models directory: $model_dir"
        echo "Copy the following files there before starting capsper:"
        [ ! -f "$model_dir/$WHISPER_MODEL_NAME" ] && echo "  - $WHISPER_MODEL_NAME"
        [ ! -f "$model_dir/$VAD_MODEL_NAME" ] && echo "  - $VAD_MODEL_NAME"
        return
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

# ─── PipeWire Device Selection & Channel Detection ───────────────────────────

# Show numbered list of PipeWire sources, let user pick by number.
# Sets PW_TARGET to the selected device name (empty = default).
select_device() {
    local binary="$1"
    PW_TARGET=""

    # Capture --pw-list output (goes to stderr)
    local list_output
    list_output=$("$binary" --pw-list 2>&1) || true

    # Extract device lines: lines after the separator that aren't blank or the footer
    local -a device_names=()
    local -a device_lines=()
    local past_separator=false
    while IFS= read -r line; do
        if [[ "$line" == *"--------"* ]]; then
            past_separator=true
            continue
        fi
        if $past_separator; then
            # Stop at blank lines or footer
            [[ -z "${line// /}" ]] && break
            [[ "$line" == *"Use --pw-target"* ]] && break
            # Extract device name (first field after leading whitespace)
            local name
            name=$(echo "$line" | awk '{print $1}')
            if [ -n "$name" ]; then
                device_names+=("$name")
                device_lines+=("$(echo "$line" | sed 's/^  //')")
            fi
        fi
    done <<< "$list_output"

    if [ ${#device_names[@]} -eq 0 ]; then
        echo "No PipeWire audio sources found."
        return
    fi

    echo ""
    echo "Available audio sources:"
    echo ""
    for i in "${!device_names[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${device_lines[$i]}"
    done
    echo ""
    printf "Select a device [1-%d] (Enter = default): " "${#device_names[@]}"
    read -r choice

    if [ -n "$choice" ]; then
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#device_names[@]}" ]; then
            PW_TARGET="${device_names[$((choice - 1))]}"
            echo "Selected: $PW_TARGET"
        else
            echo "Invalid choice. Using default device."
        fi
    else
        echo "Using default device."
    fi
}

pw_detect() {
    local binary="$1"
    local target="${2:-}"
    local detect_args=(--pw-detect)
    [ -n "$target" ] && detect_args+=(--pw-target "$target")
    "$binary" "${detect_args[@]}"
}

# ─── Systemd Service ─────────────────────────────────────────────────────────

install_service() {
    local work_dir="$1"
    local binary="$2"
    local channel="$3"
    local model_dir="$4"
    local target="${5:-}"

    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"

    local exec_start="$binary --trigger capslock --pw-channel $channel"
    exec_start="$exec_start --model $model_dir/$WHISPER_MODEL_NAME"
    exec_start="$exec_start --vad-model $model_dir/$VAD_MODEL_NAME"
    [ -n "$target" ] && exec_start="$exec_start --pw-target $target"

    cat > "$service_dir/capsper.service" <<EOF
[Unit]
Description=Capsper push-to-talk dictation

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
    systemctl --user enable capsper.service 2>/dev/null || true
    echo "capsper.service installed."
}

run_dry_run() {
    local service_file="$HOME/.config/systemd/user/capsper.service"
    local exec_start
    exec_start=$(grep '^ExecStart=' "$service_file" | sed 's/^ExecStart=//')

    if [ -z "$exec_start" ]; then
        echo "WARNING: Could not read service file, skipping validation."
        return 0
    fi

    echo ""
    echo "=== Validating Setup ==="
    echo ""

    local exit_code=0
    $exec_start --dry-run 2>&1 || exit_code=$?

    echo ""

    if [ $exit_code -ne 0 ]; then
        echo "Setup validation failed. Fix the issues above before starting the service."
        return 1
    fi

    echo "Setup validated successfully."
}

# ─── CUDA Runtime ─────────────────────────────────────────────────────────

check_cuda_libraries() {
    # libcudart and libcublas are needed at runtime by the bundled whisper.cpp CUDA backend.
    # These come from the CUDA toolkit packages (any CUDA 13.x), not the nvidia driver.
    local missing=()
    ldconfig -p 2>/dev/null | grep -q 'libcudart\.so\.13' || missing+=("libcudart.so.13")
    ldconfig -p 2>/dev/null | grep -q 'libcublas\.so\.13' || missing+=("libcublas.so.13")
    ldconfig -p 2>/dev/null | grep -q 'libcublasLt\.so\.13' || missing+=("libcublasLt.so.13")

    [ ${#missing[@]} -eq 0 ] && return

    # Find available CUDA 13.x packages (could be 13-0, 13-1, etc.)
    local cudart_pkg="" cublas_pkg=""
    if command -v apt-cache >/dev/null 2>&1; then
        cudart_pkg=$(apt-cache search --names-only '^cuda-cudart-13-' 2>/dev/null | sort -V | tail -1 | awk '{print $1}')
        cublas_pkg=$(apt-cache search --names-only '^libcublas-13-' 2>/dev/null | sort -V | tail -1 | awk '{print $1}')
    fi
    # Fallback if apt-cache didn't find anything
    : "${cudart_pkg:=cuda-cudart-13-1}"
    : "${cublas_pkg:=libcublas-13-1}"

    echo ""
    echo "=== CUDA Runtime Libraries ==="
    echo "Missing: ${missing[*]}"
    echo ""
    echo "These are provided by the CUDA 13 toolkit packages (~600 MB):"
    echo "  sudo apt install $cudart_pkg $cublas_pkg"
    echo ""
    echo "If apt can't find them, add the NVIDIA package repository first:"
    echo "  https://developer.nvidia.com/cuda-downloads"
    echo ""

    if command -v apt >/dev/null 2>&1; then
        if confirm "Try to install them now? (requires sudo)"; then
            if sudo apt install -y "$cudart_pkg" "$cublas_pkg"; then
                echo "CUDA runtime libraries installed."
                return
            else
                echo ""
                echo "apt install failed. You may need to add the NVIDIA repository first."
                echo "See: https://developer.nvidia.com/cuda-downloads"
                die "Missing CUDA runtime libraries."
            fi
        fi
    fi

    die "Missing CUDA runtime libraries. Install them with: sudo apt install $cudart_pkg $cublas_pkg"
}

# ─── Install Files ────────────────────────────────────────────────────────

install_files() {
    echo "Installing to $INSTALL_DIR ..."

    [ -d "$SCRIPT_DIR/lib" ] || die "dist/lib/ not found. If this is a git checkout, run: git lfs pull"

    mkdir -p "$INSTALL_DIR"

    # Copy bin/ and lib/ (overwrite on upgrade)
    cp -a "$SCRIPT_DIR/bin" "$INSTALL_DIR/"
    cp -a "$SCRIPT_DIR/lib" "$INSTALL_DIR/"

    # Symlink into ~/.local/bin so capsper is on PATH
    mkdir -p "$HOME/.local/bin"
    ln -sf "$INSTALL_DIR/bin/capsper" "$HOME/.local/bin/capsper"

    echo "Installed. Binary: $INSTALL_DIR/bin/capsper"
    echo "Symlink:  ~/.local/bin/capsper"

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
        echo ""
        echo "NOTE: ~/.local/bin is not on your PATH."
        echo "Add to your shell rc file:"
        echo '  export PATH="$HOME/.local/bin:$PATH"'
    fi
}

# ─── Subcommands ──────────────────────────────────────────────────────────────

cmd_install() {
    # Verify we're in a dist directory with the binary
    [ -f "$SCRIPT_DIR/bin/capsper" ] || die "capsper binary not found in $SCRIPT_DIR/bin"

    local service_file="$HOME/.config/systemd/user/capsper.service"
    local is_upgrade=false
    local update_config=false

    local was_active=false

    if [ -f "$service_file" ]; then
        is_upgrade=true
        if systemctl --user is-active --quiet capsper.service 2>/dev/null; then
            was_active=true
        fi
        echo "Previous capsper installation detected."
        if $was_active; then
            echo "Stopping current service..."
            systemctl --user stop capsper.service 2>/dev/null || true
        fi
        echo ""
        if confirm_default_no "Update configuration?"; then
            update_config=true
        fi
    fi

    if is_dev_mode; then
        echo "=== Capsper Developer Setup ==="
        echo "(detected git checkout)"
        echo ""

        local project_dir
        project_dir="$(cd "$SCRIPT_DIR/.." && pwd)"

        check_permissions

        if ! $is_upgrade || $update_config; then
            local channel="FL"
            PW_TARGET=""
            echo ""
            echo "=== Audio Configuration ==="
            if confirm "Select audio device?"; then
                select_device "$SCRIPT_DIR/bin/capsper"
            fi
            if confirm "Run microphone channel detection? (No = use default FL)"; then
                local detect_output
                detect_output=$(pw_detect "$SCRIPT_DIR/bin/capsper" "$PW_TARGET")
                echo "$detect_output"
                channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
                [ -z "$channel" ] && channel="FL"
            else
                echo "Using default channel: FL"
            fi

            install_service "$project_dir" "$SCRIPT_DIR/bin/capsper" "$channel" "$project_dir/whisper.cpp/models" "$PW_TARGET"
        fi
    else
        echo "=== Capsper Installer ==="
        echo ""

        # Check runtime deps (always, even on upgrade)
        require_cmd nvidia-smi "NVIDIA driver required for CUDA inference."
        check_cuda_libraries
        command -v pw-cli >/dev/null 2>&1 || echo "WARNING: pw-cli not found. PipeWire may not be installed."

        # Copy files to ~/.local/share/capsper/ (always, this is the upgrade)
        install_files

        # Download models (always, in case new models are needed)
        download_models "$INSTALL_DIR/models"

        # Permissions (always, even on upgrade)
        check_permissions

        if ! $is_upgrade || $update_config; then
            # Audio configuration
            local channel="FL"
            PW_TARGET=""
            echo ""
            echo "=== Audio Configuration ==="
            if confirm "Select audio device?"; then
                select_device "$INSTALL_DIR/bin/capsper"
            fi
            if confirm "Run microphone channel detection? (No = use default FL)"; then
                local detect_output
                detect_output=$(pw_detect "$INSTALL_DIR/bin/capsper" "$PW_TARGET")
                echo "$detect_output"
                channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
                [ -z "$channel" ] && channel="FL"
            else
                echo "Using default channel: FL"
            fi

            # Systemd service
            install_service "$INSTALL_DIR" "$INSTALL_DIR/bin/capsper" "$channel" "$INSTALL_DIR/models" "$PW_TARGET"
        fi
    fi

    echo ""
    if run_dry_run; then
        if $is_upgrade && $was_active; then
            echo "Restarting service..."
            systemctl --user restart capsper.service
            echo "Service restarted. Check status with:"
            echo "  systemctl --user status capsper.service"
        elif $is_upgrade; then
            echo "Service was not running before upgrade, leaving it stopped."
            echo "Start manually with:"
            echo "  systemctl --user start capsper.service"
        elif confirm "Start the dictation service now?"; then
            systemctl --user restart capsper.service
            echo "Service started. Check status with:"
            echo "  systemctl --user status capsper.service"
        else
            echo ""
            echo "Start manually with:"
            echo "  systemctl --user start capsper.service"
        fi
    else
        echo ""
        echo "Start manually with:"
        echo "  systemctl --user start capsper.service"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-install}" in
    install)    cmd_install ;;
    pw-detect)  shift; pw_detect "$SCRIPT_DIR/bin/capsper" "$@" ;;
    *)          die "Unknown command: $1. Usage: install.sh [install|pw-detect]" ;;
esac
