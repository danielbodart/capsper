#!/bin/bash

# Whisper Push-to-Talk Dictation Tool
# Runs whisper.cpp continuously, only processes output when key is held

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
WHISPER_BIN="$SCRIPT_DIR/../whisper.cpp/build/bin/whisper-stream"
WHISPER_MODEL="$SCRIPT_DIR/../whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin"
LOG_FILE="/tmp/whisper-dictation.log"
KEYCODE=202
KEY_STATE_FILE="/tmp/key_state"
KEYBOARD_DEVICE_ID=12

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    jobs -p | xargs -r kill 2>/dev/null || true
    [[ -f "$KEY_STATE_FILE" ]] && rm -f "$KEY_STATE_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    command -v xinput >/dev/null || missing_deps+=("xinput")
    command -v xdotool >/dev/null || missing_deps+=("xdotool")
    [[ -f "$WHISPER_BIN" ]] || missing_deps+=("whisper-stream binary")
    [[ -f "$WHISPER_MODEL" ]] || missing_deps+=("whisper model")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing_deps[*]}" >&2
        exit 1
    fi
}

# Monitor key state with debounce
monitor_key() {
    # Get device name for display
    local device_name=$(xinput list | grep "id=$KEYBOARD_DEVICE_ID" | sed 's/.*↳[[:space:]]*//' | sed 's/[[:space:]]*id=.*//')
    echo "Monitoring key $KEYCODE on device: $device_name (ID: $KEYBOARD_DEVICE_ID)"
    
    echo "0" > "$KEY_STATE_FILE"
    local debounce_pid=""
    
    # Function to handle delayed release
    delayed_release() {
        sleep 1
        echo "0" > "$KEY_STATE_FILE"
        echo "Key released"
    }
    
    xinput test "$KEYBOARD_DEVICE_ID" | while read -r line; do
        if [[ "$line" =~ key\ press\ +$KEYCODE ]]; then
            # Kill any pending release
            [[ -n "$debounce_pid" ]] && kill "$debounce_pid" 2>/dev/null || true
            debounce_pid=""
            
            # Only trigger if currently not pressed
            if [[ "$(cat "$KEY_STATE_FILE" 2>/dev/null)" == "0" ]]; then
                echo "1" > "$KEY_STATE_FILE"
                echo "Key pressed"
            fi
        elif [[ "$line" =~ key\ release\ +$KEYCODE ]]; then
            # Kill any existing delayed release and start a new one
            [[ -n "$debounce_pid" ]] && kill "$debounce_pid" 2>/dev/null || true
            delayed_release &
            debounce_pid=$!
        fi
    done
}

# Check if key is pressed
is_key_pressed() {
    [[ -f "$KEY_STATE_FILE" ]] && [[ "$(cat "$KEY_STATE_FILE" 2>/dev/null)" == "1" ]]
}

# Process whisper output
process_whisper_output() {
    "$WHISPER_BIN" -m "$WHISPER_MODEL" 2>>"$LOG_FILE" | while read -r line; do
        if is_key_pressed && [[ -n "$line" ]]; then
            # Keep only text after the last [2K (line clear), remove other ANSI codes, brackets, "Thank you.", and trim
            clean_line=$(echo "$line" | sed 's/.*\x1b\[2K//' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/\[[^]]*\]//g' | sed 's/Thank you\.//g' | sed 's/[[:space:]]\+/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$clean_line" ]]; then
                xdotool type "$clean_line "
            fi
        fi
    done
}

# Main function
main() {
    echo "Starting Whisper Push-to-Talk Dictation Tool..."
    check_dependencies
    > "$LOG_FILE"
    echo "Press and hold key $KEYCODE to dictate..."
    
    monitor_key &
    process_whisper_output
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
