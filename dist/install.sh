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
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_NAME}"

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"
RECORDINGS_DIR="$INSTALL_DIR/recordings"
NEEDS_REBOOT=false

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
            NEEDS_REBOOT=true
            echo "Added to 'input' group."
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

    if [ -f "$model_dir/$WHISPER_MODEL_NAME" ]; then
        echo "Whisper model already present."
        return
    fi

    echo "Missing: Whisper model (large-v3-turbo-q5_0, ~574 MB)"

    if ! confirm "Download now?"; then
        echo ""
        echo "Models directory: $model_dir"
        echo "Copy $WHISPER_MODEL_NAME there before starting capsper."
        return
    fi

    require_cmd curl "Install curl to download models."
    echo "Downloading Whisper model..."
    curl -L --progress-bar -o "$model_dir/$WHISPER_MODEL_NAME" "$WHISPER_MODEL_URL"
    echo "Model downloaded."
}

# ─── PipeWire Channel Detection & Gain Calibration ───────────────────────────

# Run the interactive setup wizard. Device selection, channel detection, and
# gain calibration all happen inside the binary. Parseable output (CHANNEL=,
# GAIN=) goes to stdout; interactive prompts go to stderr.
pw_detect() {
    local binary="$1"
    "$binary" --pw-detect
}

# ─── Systemd Service ─────────────────────────────────────────────────────────

install_service() {
    local work_dir="$1"
    local binary="$2"
    local channel="$3"
    local model_dir="$4"
    local target="${5:-}"
    local with_updates="${6:-false}"

    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"

    local domain_terms="${7:-}"
    local enable_recordings="${8:-false}"
    local low_latency="${9:-false}"
    local gain="${10:-1.0}"

    local exec_start="$binary --trigger capslock --pw-channel $channel"
    if [ -n "$gain" ] && [ "$gain" != "1.0" ] && [ "$gain" != "1" ]; then
        exec_start="$exec_start --pw-gain $gain"
    fi
    exec_start="$exec_start --model $model_dir/$WHISPER_MODEL_NAME"
    [ -n "$target" ] && exec_start="$exec_start --pw-target $target"
    [ -n "$domain_terms" ] && exec_start="$exec_start --domain-terms $domain_terms"
    if $enable_recordings; then
        mkdir -p "$RECORDINGS_DIR"
        exec_start="$exec_start --record-dir $RECORDINGS_DIR"
    fi
    if $low_latency; then
        exec_start="$exec_start --low-latency"
    fi

    {
        echo "[Unit]"
        echo "Description=Capsper push-to-talk dictation"
        if $with_updates; then
            echo "StartLimitBurst=3"
            echo "StartLimitIntervalSec=60"
            echo "OnFailure=capsper-rollback.service"
        fi
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "WorkingDirectory=$work_dir"
        if $with_updates; then
            echo "ExecStartPre=$INSTALL_DIR/capsper-apply-update.sh"
        fi
        echo "ExecStart=$exec_start"
        echo "Restart=always"
        echo "RestartSec=5"
        echo "Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > "$service_dir/capsper.service"

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

# ─── Update Infrastructure ─────────────────────────────────────────────────

has_auto_update() {
    [ -f "$HOME/.config/systemd/user/capsper-update.timer" ]
}

extract_service_config() {
    local service_file="$HOME/.config/systemd/user/capsper.service"
    [ -f "$service_file" ] || return 1

    local exec_start
    exec_start=$(grep '^ExecStart=' "$service_file" | sed 's/^ExecStart=//')

    SAVED_CHANNEL=$(echo "$exec_start" | sed -n 's/.*--pw-channel \([^ ]*\).*/\1/p')
    SAVED_CHANNEL="${SAVED_CHANNEL:-FL}"

    SAVED_TARGET=$(echo "$exec_start" | sed -n 's/.*--pw-target \([^ ]*\).*/\1/p')
    SAVED_TARGET="${SAVED_TARGET:-}"

    SAVED_DOMAIN_TERMS=$(echo "$exec_start" | sed -n 's/.*--domain-terms \([^ ]*\).*/\1/p')
    SAVED_DOMAIN_TERMS="${SAVED_DOMAIN_TERMS:-}"

    SAVED_RECORDINGS_ENABLED=false
    echo "$exec_start" | grep -q -- '--record-dir' && SAVED_RECORDINGS_ENABLED=true

    SAVED_LOW_LATENCY=false
    echo "$exec_start" | grep -q -- '--low-latency' && SAVED_LOW_LATENCY=true

    SAVED_GAIN=$(echo "$exec_start" | sed -n 's/.*--pw-gain \([^ ]*\).*/\1/p')
    SAVED_GAIN="${SAVED_GAIN:-1.0}"
}

install_update_timer() {
    local service_dir="$HOME/.config/systemd/user"

    cat > "$service_dir/capsper-update.service" <<EOF
[Unit]
Description=Check for capsper updates

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/capsper-update.sh
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
EOF

    cat > "$service_dir/capsper-update.timer" <<EOF
[Unit]
Description=Daily capsper update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now capsper-update.timer 2>/dev/null || true
    echo "capsper-update.timer installed."
}

install_rollback_service() {
    local service_dir="$HOME/.config/systemd/user"

    cat > "$service_dir/capsper-rollback.service" <<EOF
[Unit]
Description=Capsper auto-rollback

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/capsper-rollback.sh
EOF

    systemctl --user daemon-reload
    echo "capsper-rollback.service installed."
}

# ─── Install Files ────────────────────────────────────────────────────────

install_files() {
    echo "Installing to $INSTALL_DIR ..."

    [ -d "$SCRIPT_DIR/lib" ] || die "dist/lib/ not found. If this is a git checkout, run: git lfs pull"
    [ -f "$SCRIPT_DIR/VERSION" ] || die "VERSION file not found in dist."

    local ver
    ver=$(cat "$SCRIPT_DIR/VERSION")
    local release_dir="$INSTALL_DIR/releases/v$ver"

    mkdir -p "$release_dir"

    # Copy bin/, lib/, and models/ into versioned directory
    cp -a "$SCRIPT_DIR/bin" "$release_dir/"
    cp -a "$SCRIPT_DIR/lib" "$release_dir/"
    [ -d "$SCRIPT_DIR/models" ] && cp -a "$SCRIPT_DIR/models" "$release_dir/"
    cp "$SCRIPT_DIR/VERSION" "$release_dir/"

    # Save current version for rollback (if upgrading)
    local current_target
    current_target=$(readlink "$INSTALL_DIR/current" 2>/dev/null || true)
    if [ -n "$current_target" ]; then
        local current_name
        current_name=$(basename "$current_target")
        if [ "$current_name" != "v$ver" ]; then
            echo "$current_name" > "$INSTALL_DIR/.previous-version"
            date +%s > "$INSTALL_DIR/.update-applied-at"
        fi
    fi

    # Atomic symlink swap
    ln -sfn "releases/v$ver" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Install update scripts
    for script in capsper-update.sh capsper-apply-update.sh capsper-rollback.sh; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$script"
        fi
    done

    # Clean up old flat layout (migration from pre-versioned installs)
    if [ -d "$INSTALL_DIR/bin" ] && [ ! -L "$INSTALL_DIR/bin" ]; then
        rm -rf "${INSTALL_DIR:?}/bin" "${INSTALL_DIR:?}/lib"
        echo "Migrated from flat layout to versioned directories."
    fi

    # Clean up old releases (keep current + previous)
    local prev
    prev=$(cat "$INSTALL_DIR/.previous-version" 2>/dev/null || true)
    for dir in "$INSTALL_DIR/releases"/v*; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        [ "$name" = "v$ver" ] && continue
        [ "$name" = "$prev" ] && continue
        echo "Removing old release: $name"
        rm -rf "$dir"
    done

    # Symlink into ~/.local/bin so capsper is on PATH
    mkdir -p "$HOME/.local/bin"
    ln -sf "$INSTALL_DIR/current/bin/capsper" "$HOME/.local/bin/capsper"

    echo "Installed v$ver. Binary: $INSTALL_DIR/current/bin/capsper"
    echo "Symlink:  ~/.local/bin/capsper"

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
        echo ""
        echo "NOTE: ~/.local/bin is not on your PATH."
        echo "Add to your shell rc file:"
        # shellcheck disable=SC2016
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
            local gain="1.0"
            echo ""
            echo "=== Audio Configuration ==="
            if confirm "Run microphone channel detection? (No = use default FL, no gain boost)"; then
                local detect_output
                detect_output=$(pw_detect "$SCRIPT_DIR/bin/capsper")
                channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
                gain=$(echo "$detect_output" | grep '^GAIN=' | tail -1 | cut -d= -f2)
                [ -z "$channel" ] && channel="FL"
                [ -z "$gain" ] && gain="1.0"
            else
                echo "Using default channel: FL, gain: 1.0"
            fi

            # Domain terms
            local domain_terms=""
            echo ""
            echo "=== Domain Terms (optional) ==="
            echo "Improve accuracy for jargon and technical terms by providing a text file"
            echo "of words you use often (e.g. tool names, project names, acronyms)."
            if confirm_default_no "Do you have a domain terms file?"; then
                printf 'Path to terms file: '
                read -r domain_terms
                if [ -n "$domain_terms" ] && [ ! -f "$domain_terms" ]; then
                    echo "WARNING: File not found: $domain_terms (continuing anyway)"
                fi
            fi

            # Debug recordings
            local enable_recordings=false
            echo ""
            echo "=== Debug Recordings (optional) ==="
            echo "Record audio snippets and transcription logs for troubleshooting."
            echo "Keeps the last 50 utterances in: $RECORDINGS_DIR"
            echo "Recordings are cleared automatically on version updates."
            if confirm_default_no "Enable debug recordings?"; then
                enable_recordings=true
            fi

            # Low-latency mode
            local low_latency=false
            echo ""
            echo "=== Low-Latency Mode (optional) ==="
            echo "Keeps the microphone stream open between presses, saving ~300ms on"
            echo "first-emit latency. Trade-off: your desktop microphone indicator will"
            echo "stay visible at all times, not just while speaking."
            if confirm_default_no "Enable low-latency mode?"; then
                low_latency=true
            fi

            install_service "$project_dir" "$SCRIPT_DIR/bin/capsper" "$channel" "$SCRIPT_DIR/models" "" false "$domain_terms" $enable_recordings $low_latency "$gain"
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
            local gain="1.0"
            echo ""
            echo "=== Audio Configuration ==="
            if confirm "Run microphone channel detection? (No = use default FL, no gain boost)"; then
                local detect_output
                detect_output=$(pw_detect "$INSTALL_DIR/current/bin/capsper")
                channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
                gain=$(echo "$detect_output" | grep '^GAIN=' | tail -1 | cut -d= -f2)
                [ -z "$channel" ] && channel="FL"
                [ -z "$gain" ] && gain="1.0"
            else
                echo "Using default channel: FL, gain: 1.0"
            fi

            # Domain terms
            local domain_terms=""
            echo ""
            echo "=== Domain Terms (optional) ==="
            echo "Improve accuracy for jargon and technical terms by providing a text file"
            echo "of words you use often (e.g. tool names, project names, acronyms)."
            if confirm_default_no "Do you have a domain terms file?"; then
                printf 'Path to terms file: '
                read -r domain_terms
                if [ -n "$domain_terms" ] && [ ! -f "$domain_terms" ]; then
                    echo "WARNING: File not found: $domain_terms (continuing anyway)"
                fi
            fi

            # Debug recordings
            local enable_recordings=false
            echo ""
            echo "=== Debug Recordings (optional) ==="
            echo "Record audio snippets and transcription logs for troubleshooting."
            echo "Keeps the last 50 utterances in: $RECORDINGS_DIR"
            echo "Recordings are cleared automatically on version updates."
            if confirm_default_no "Enable debug recordings?"; then
                enable_recordings=true
            fi

            # Low-latency mode
            local low_latency=false
            echo ""
            echo "=== Low-Latency Mode (optional) ==="
            echo "Keeps the microphone stream open between presses, saving ~300ms on"
            echo "first-emit latency. Trade-off: your desktop microphone indicator will"
            echo "stay visible at all times, not just while speaking."
            if confirm_default_no "Enable low-latency mode?"; then
                low_latency=true
            fi

            # Auto-updates
            local enable_updates=true
            echo ""
            if ! confirm "Enable automatic updates?"; then
                enable_updates=false
            fi

            install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/capsper" "$channel" "$INSTALL_DIR/models" "" $enable_updates "$domain_terms" $enable_recordings $low_latency "$gain"

            if $enable_updates; then
                install_update_timer
                install_rollback_service
            fi
        else
            # Upgrade without config change: preserve audio settings, update paths
            extract_service_config

            if has_auto_update; then
                # Auto-update already configured: keep it, just update paths
                install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/capsper" "$SAVED_CHANNEL" "$INSTALL_DIR/models" "$SAVED_TARGET" true "$SAVED_DOMAIN_TERMS" "$SAVED_RECORDINGS_ENABLED" "$SAVED_LOW_LATENCY" "$SAVED_GAIN"
            else
                # Pre-auto-update install: offer to enable
                local enable_updates=true
                echo ""
                if ! confirm "Enable automatic updates?"; then
                    enable_updates=false
                fi

                install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/capsper" "$SAVED_CHANNEL" "$INSTALL_DIR/models" "$SAVED_TARGET" $enable_updates "$SAVED_DOMAIN_TERMS" "$SAVED_RECORDINGS_ENABLED" "$SAVED_LOW_LATENCY" "$SAVED_GAIN"

                if $enable_updates; then
                    install_update_timer
                    install_rollback_service
                fi
            fi
        fi
    fi

    echo ""
    if $NEEDS_REBOOT; then
        echo "=== Reboot Required ==="
        echo "You were added to the 'input' group. This only takes effect after a reboot."
        echo "The service is enabled and will start automatically on boot."
        echo ""
        echo "Reboot now, and capsper will be ready when you log back in."
    elif run_dry_run; then
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
    pw-detect)  pw_detect "$SCRIPT_DIR/bin/capsper" ;;
    *)          die "Unknown command: $1. Usage: install.sh [install|pw-detect]" ;;
esac
