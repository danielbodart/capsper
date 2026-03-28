#!/usr/bin/env bash
set -euo pipefail

# macOS installer for capsper.
# Ships in the dist tarball alongside the binary.
#
# In a git checkout (dev mode), installs in-situ pointing at the source tree.
# Otherwise, copies to ~/.local/share/capsper/ for a proper user install.
#
# Usage:
#   ./install.sh              Full interactive setup (download models, permissions, LaunchAgent)

# shellcheck source=dist/install-common.sh
source "$(cd "$(dirname "$0")" >/dev/null && pwd)/install-common.sh"

PLIST_LABEL="com.capsper.capsper"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$PLIST_LABEL.plist"

UPDATE_PLIST_LABEL="com.capsper.update"
UPDATE_PLIST_PATH="$PLIST_DIR/$UPDATE_PLIST_LABEL.plist"

# ─── Quarantine ──────────────────────────────────────────────────────────────

# Remove macOS quarantine flag so Gatekeeper doesn't block the binary.
# Permissions (Accessibility, Microphone) are handled by the binary at runtime.
clear_quarantine() {
    local binary="$1"
    xattr -d com.apple.quarantine "$binary" 2>/dev/null || true
}

# ─── LaunchAgent Service ─────────────────────────────────────────────────────

install_service() {
    local binary="$1"
    local model_dir="$2"
    shift 2

    # Build command args
    local args=("$binary" "--trigger" "capslock" "--model" "$model_dir/nemotron")

    # Optional args passed as key=value pairs
    for arg in "$@"; do
        case "$arg" in
            drop-terms=*)  args+=("--drop-terms" "${arg#*=}") ;;
            record-dir=*)  args+=("--record-dir" "${arg#*=}") ;;
            low-latency)   args+=("--low-latency") ;;
            audio-gain=*)  args+=("--audio-gain" "${arg#*=}") ;;
        esac
    done

    mkdir -p "$PLIST_DIR"

    # Build ProgramArguments array
    local prog_args=""
    for a in "${args[@]}"; do
        prog_args="$prog_args        <string>$a</string>
"
    done

    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
$prog_args    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/capsper.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/capsper.log</string>
</dict>
</plist>
EOF

    echo "LaunchAgent installed: $PLIST_PATH"
}

# ─── Auto-Update Timer ────────────────────────────────────────────────────────

install_update_timer() {
    cat > "$UPDATE_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$UPDATE_PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/capsper-update.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>12</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/update.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/update.log</string>
</dict>
</plist>
EOF

    launchctl bootout "gui/$(id -u)/$UPDATE_PLIST_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$UPDATE_PLIST_PATH"
    echo "Update timer installed (daily at noon)."
}

# ─── Service Control ──────────────────────────────────────────────────────────

stop_service() {
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
}

start_service() {
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
}

restart_service() {
    stop_service
    sleep 1
    start_service
}

is_service_running() {
    launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
}

# ─── Config Extraction (for upgrades) ────────────────────────────────────────

extract_service_config() {
    [ -f "$PLIST_PATH" ] || return 1

    # Parse ProgramArguments from plist via plutil
    local args_json
    args_json=$(plutil -convert json -o - "$PLIST_PATH" 2>/dev/null) || return 1
    local args_str
    args_str=$(echo "$args_json" | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin).get('ProgramArguments',[])))" 2>/dev/null) || return 1

    SAVED_DROP_TERMS=$(echo "$args_str" | sed -n 's/.*--drop-terms \([^ ]*\).*/\1/p')
    SAVED_DROP_TERMS="${SAVED_DROP_TERMS:-}"

    SAVED_RECORDINGS_ENABLED=false
    echo "$args_str" | grep -q -- '--record-dir' && SAVED_RECORDINGS_ENABLED=true

    SAVED_LOW_LATENCY=false
    echo "$args_str" | grep -q -- '--low-latency' && SAVED_LOW_LATENCY=true

    SAVED_GAIN=$(echo "$args_str" | sed -n 's/.*--\(audio\|pw\)-gain \([^ ]*\).*/\2/p')
    SAVED_GAIN="${SAVED_GAIN:-1.0}"
}

# ─── Main Install ─────────────────────────────────────────────────────────────

cmd_install() {
    [ -f "$SCRIPT_DIR/bin/capsper" ] || die "capsper binary not found in $SCRIPT_DIR/bin"

    local is_upgrade=false
    local update_config=false
    local was_running=false

    if [ -f "$PLIST_PATH" ]; then
        is_upgrade=true
        if is_service_running; then
            was_running=true
        fi
        echo "Previous capsper installation detected."
        if $was_running; then
            echo "Stopping current service..."
            stop_service
        fi
        echo ""
        if confirm_default_no "Update configuration?"; then
            update_config=true
        fi
    fi

    if is_dev_mode; then
        echo "=== Capsper Developer Setup (macOS) ==="
        echo "(detected git checkout)"
        echo ""

        clear_quarantine "$SCRIPT_DIR/bin/capsper"

        if ! $is_upgrade || $update_config; then
            # Build service args
            local service_args=()

            # Drop terms
            echo ""
            echo "=== Drop Terms (optional) ==="
            echo "Suppress filler phrases (e.g. \"Thank you.\", \"you know\")."
            if confirm_default_no "Do you have a drop terms file?"; then
                printf 'Path to drop terms file: '
                read -r drop_terms
                if [ -n "$drop_terms" ]; then
                    service_args+=("drop-terms=$drop_terms")
                fi
            fi

            # Debug recordings
            echo ""
            echo "=== Debug Recordings (optional) ==="
            echo "Record audio snippets and transcription logs for troubleshooting."
            if confirm_default_no "Enable debug recordings?"; then
                mkdir -p "$RECORDINGS_DIR"
                service_args+=("record-dir=$RECORDINGS_DIR")
            fi

            install_service "$SCRIPT_DIR/bin/capsper" "$SCRIPT_DIR/models" "${service_args[@]+"${service_args[@]}"}"
        fi
    else
        echo "=== Capsper Installer (macOS) ==="
        echo ""

        install_files
        clear_quarantine "$INSTALL_DIR/current/bin/capsper"
        download_models "$INSTALL_DIR/models"

        if ! $is_upgrade || $update_config; then
            local service_args=()

            # Drop terms
            echo ""
            echo "=== Drop Terms (optional) ==="
            echo "Suppress filler phrases (e.g. \"Thank you.\", \"you know\")."
            if confirm_default_no "Do you have a drop terms file?"; then
                printf 'Path to drop terms file: '
                read -r drop_terms
                if [ -n "$drop_terms" ]; then
                    service_args+=("drop-terms=$drop_terms")
                fi
            fi

            # Debug recordings
            echo ""
            echo "=== Debug Recordings (optional) ==="
            echo "Record audio snippets and transcription logs for troubleshooting."
            if confirm_default_no "Enable debug recordings?"; then
                mkdir -p "$RECORDINGS_DIR"
                service_args+=("record-dir=$RECORDINGS_DIR")
            fi

            install_service "$INSTALL_DIR/current/bin/capsper" "$INSTALL_DIR/models" "${service_args[@]+"${service_args[@]}"}"
            # TODO: install_update_timer — needs capsper-update.sh macOS support first
        else
            # Upgrade without config change: preserve settings
            extract_service_config

            local service_args=()
            [ -n "$SAVED_DROP_TERMS" ] && service_args+=("drop-terms=$SAVED_DROP_TERMS")
            $SAVED_RECORDINGS_ENABLED && service_args+=("record-dir=$RECORDINGS_DIR")
            $SAVED_LOW_LATENCY && service_args+=("low-latency")
            [ "$SAVED_GAIN" != "1.0" ] && [ "$SAVED_GAIN" != "1" ] && service_args+=("audio-gain=$SAVED_GAIN")

            install_service "$INSTALL_DIR/current/bin/capsper" "$INSTALL_DIR/models" "${service_args[@]+"${service_args[@]}"}"
            # TODO: install_update_timer — needs capsper-update.sh macOS support first
        fi
    fi

    echo ""
    if $is_upgrade && $was_running; then
        echo "Restarting service..."
        restart_service
        echo "Service restarted. Check logs with:"
        echo "  tail -f $INSTALL_DIR/capsper.log"
    elif $is_upgrade; then
        echo "Service was not running before upgrade."
        echo "Start with:  launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
    elif confirm "Start the dictation service now?"; then
        start_service
        echo "Service started. Check logs with:"
        echo "  tail -f $INSTALL_DIR/capsper.log"
    else
        echo "Start manually with:"
        echo "  launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-install}" in
    install)    cmd_install ;;
    *)          die "Unknown command: $1. Usage: install.sh [install]" ;;
esac
