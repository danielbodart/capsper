#!/usr/bin/env bash
set -euo pipefail

# Linux installer for capsper.
# Ships in the dist tarball alongside the binary and shared libs.
#
# In a git checkout (dev mode), installs in-situ pointing at the source tree.
# Otherwise, copies to ~/.local/share/capsper/ for a proper user install.
#
# Usage:
#   ./install.sh              Full interactive setup (download models, permissions, systemd)
#   ./install.sh pw-detect    Detect best PipeWire microphone channel (delegates to capsper --pw-detect)

# shellcheck source=dist/install-common.sh
source "$(cd "$(dirname "$0")" >/dev/null && pwd)/install-common.sh"

NEEDS_REBOOT=false

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

# ─── PipeWire Channel Detection & Gain Calibration ───────────────────────────

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
    local drop_terms="${7:-}"
    local enable_recordings="${8:-false}"
    local low_latency="${9:-false}"
    local gain="${10:-1.0}"

    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"

    local exec_start="$binary --trigger capslock --pw-channel $channel"
    if [ -n "$gain" ] && [ "$gain" != "1.0" ] && [ "$gain" != "1" ]; then
        exec_start="$exec_start --pw-gain $gain"
    fi
    exec_start="$exec_start --model $model_dir/nemotron"
    [ -n "$target" ] && exec_start="$exec_start --pw-target $target"
    [ -n "$drop_terms" ] && exec_start="$exec_start --drop-terms $drop_terms"
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

# ─── Config Extraction (for upgrades) ────────────────────────────────────────

extract_service_config() {
    local service_file="$HOME/.config/systemd/user/capsper.service"
    [ -f "$service_file" ] || return 1

    local exec_start
    exec_start=$(grep '^ExecStart=' "$service_file" | sed 's/^ExecStart=//')

    SAVED_CHANNEL=$(echo "$exec_start" | sed -n 's/.*--pw-channel \([^ ]*\).*/\1/p')
    SAVED_CHANNEL="${SAVED_CHANNEL:-FL}"

    SAVED_TARGET=$(echo "$exec_start" | sed -n 's/.*--pw-target \([^ ]*\).*/\1/p')
    SAVED_TARGET="${SAVED_TARGET:-}"

    SAVED_DROP_TERMS=$(echo "$exec_start" | sed -n 's/.*--drop-terms \([^ ]*\).*/\1/p')
    SAVED_DROP_TERMS="${SAVED_DROP_TERMS:-}"

    SAVED_RECORDINGS_ENABLED=false
    echo "$exec_start" | grep -q -- '--record-dir' && SAVED_RECORDINGS_ENABLED=true

    SAVED_LOW_LATENCY=false
    echo "$exec_start" | grep -q -- '--low-latency' && SAVED_LOW_LATENCY=true

    SAVED_GAIN=$(echo "$exec_start" | sed -n 's/.*--pw-gain \([^ ]*\).*/\1/p')
    SAVED_GAIN="${SAVED_GAIN:-1.0}"
}

# ─── Auto-Update Infrastructure ──────────────────────────────────────────────

has_auto_update() {
    [ -f "$HOME/.config/systemd/user/capsper-update.timer" ]
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

# ─── Dry-Run Validation (Linux) ──────────────────────────────────────────────

run_dry_run_linux() {
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

# ─── Main Install ─────────────────────────────────────────────────────────────

cmd_install() {
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

            local drop_terms=""
            echo ""
            echo "=== Drop Terms (optional) ==="
            echo "Suppress filler phrases (e.g. \"Thank you.\", \"you know\")."
            if confirm_default_no "Do you have a drop terms file?"; then
                printf 'Path to drop terms file: '
                read -r drop_terms
                if [ -n "$drop_terms" ] && [ ! -f "$drop_terms" ]; then
                    echo "WARNING: File not found: $drop_terms (continuing anyway)"
                fi
            fi

            local enable_recordings=false
            echo ""
            echo "=== Debug Recordings (optional) ==="
            echo "Record audio snippets and transcription logs for troubleshooting."
            if confirm_default_no "Enable debug recordings?"; then
                enable_recordings=true
            fi

            local low_latency=false
            echo ""
            echo "=== Low-Latency Mode (optional) ==="
            echo "Keeps the microphone stream open between presses, saving ~300ms on"
            echo "first-emit latency. Trade-off: your desktop microphone indicator will"
            echo "stay visible at all times, not just while speaking."
            if confirm_default_no "Enable low-latency mode?"; then
                low_latency=true
            fi

            install_service "$project_dir" "$SCRIPT_DIR/bin/capsper" "$channel" "$SCRIPT_DIR/models" "" false "$drop_terms" $enable_recordings $low_latency "$gain"
        fi
    else
        echo "=== Capsper Installer ==="
        echo ""

        command -v pw-cli >/dev/null 2>&1 || echo "WARNING: pw-cli not found. PipeWire may not be installed."

        install_files
        download_models "$INSTALL_DIR/models"
        check_permissions

        if ! $is_upgrade || $update_config; then
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

            local drop_terms=""
            echo ""
            echo "=== Drop Terms (optional) ==="
            echo "Suppress filler phrases (e.g. \"Thank you.\", \"you know\")."
            if confirm_default_no "Do you have a drop terms file?"; then
                printf 'Path to drop terms file: '
                read -r drop_terms
                if [ -n "$drop_terms" ] && [ ! -f "$drop_terms" ]; then
                    echo "WARNING: File not found: $drop_terms (continuing anyway)"
                fi
            fi

            local enable_recordings=false
            echo ""
            echo "=== Debug Recordings (optional) ==="
            echo "Record audio snippets and transcription logs for troubleshooting."
            if confirm_default_no "Enable debug recordings?"; then
                enable_recordings=true
            fi

            local low_latency=false
            echo ""
            echo "=== Low-Latency Mode (optional) ==="
            echo "Keeps the microphone stream open between presses, saving ~300ms on"
            echo "first-emit latency. Trade-off: your desktop microphone indicator will"
            echo "stay visible at all times, not just while speaking."
            if confirm_default_no "Enable low-latency mode?"; then
                low_latency=true
            fi

            local enable_updates=true
            echo ""
            if ! confirm "Enable automatic updates?"; then
                enable_updates=false
            fi

            install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/capsper" "$channel" "$INSTALL_DIR/models" "" $enable_updates "$drop_terms" $enable_recordings $low_latency "$gain"

            if $enable_updates; then
                install_update_timer
                install_rollback_service
            fi
        else
            extract_service_config

            if has_auto_update; then
                install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/capsper" "$SAVED_CHANNEL" "$INSTALL_DIR/models" "$SAVED_TARGET" true "$SAVED_DROP_TERMS" "$SAVED_RECORDINGS_ENABLED" "$SAVED_LOW_LATENCY" "$SAVED_GAIN"
            else
                local enable_updates=true
                echo ""
                if ! confirm "Enable automatic updates?"; then
                    enable_updates=false
                fi

                install_service "$INSTALL_DIR" "$INSTALL_DIR/current/bin/capsper" "$SAVED_CHANNEL" "$INSTALL_DIR/models" "$SAVED_TARGET" $enable_updates "$SAVED_DROP_TERMS" "$SAVED_RECORDINGS_ENABLED" "$SAVED_LOW_LATENCY" "$SAVED_GAIN"

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
    elif run_dry_run_linux; then
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
