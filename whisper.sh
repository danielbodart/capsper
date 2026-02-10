#!/bin/bash

# SimulStreaming Push-to-Talk Dictation Tool
# Uses SimulStreaming server for speech recognition

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
SIMUL_DIR="$SCRIPT_DIR/../SimulStreaming"
SIMUL_SERVER="simulstreaming_whisper_server.py"
SIMUL_HOST="localhost"
SIMUL_PORT=43007
LOG_FILE="/tmp/whisper-dictation.log"
KEYCODE=202
KEY_STATE_FILE="/tmp/key_state"
KEYBOARD_DEVICE_ID=12

# PIDs for cleanup
SERVER_PID=""
ARECORD_PID=""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    jobs -p | xargs -r kill 2>/dev/null || true
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -n "$ARECORD_PID" ]] && kill "$ARECORD_PID" 2>/dev/null || true
    [[ -f "$KEY_STATE_FILE" ]] && rm -f "$KEY_STATE_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Check dependencies
check_dependencies() {
    local missing_deps=()

    command -v xinput >/dev/null || missing_deps+=("xinput")
    command -v xdotool >/dev/null || missing_deps+=("xdotool")
    command -v arecord >/dev/null || missing_deps+=("arecord")
    command -v nc >/dev/null || missing_deps+=("nc")
    command -v python3 >/dev/null || missing_deps+=("python3")
    command -v mise >/dev/null || missing_deps+=("mise")
    [[ -f "$SIMUL_DIR/$SIMUL_SERVER" ]] || missing_deps+=("simulstreaming server script")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing_deps[*]}" >&2
        exit 1
    fi
}

# Start the SimulStreaming server
start_server() {
    echo "Starting SimulStreaming server..."
    (cd "$SIMUL_DIR" && mise exec -- python3 "$SIMUL_SERVER" --vac --warmup-file "$SCRIPT_DIR/jfk.wav" --model_path ./large-v3-turbo.pt) >> "$LOG_FILE" 2>&1 &
    SERVER_PID=$!

    # Wait for server to be listening (up to 30 seconds for model loading)
    echo "Waiting for server to load model and start listening..."
    local max_wait=300  # 5 minutes for first-time model download
    local waited=0
    while ! ss -tlnp 2>/dev/null | grep -q ":$SIMUL_PORT"; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "ERROR: SimulStreaming server failed to start. Check $LOG_FILE" >&2
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $max_wait ]]; then
            echo "ERROR: Server did not start listening within $max_wait seconds" >&2
            exit 1
        fi
    done
    echo "Server started (PID: $SERVER_PID)"
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

# Process SimulStreaming output
process_simul_output() {
    # Stream audio to server and process output
    arecord -f S16_LE -c1 -r 16000 -t raw -D default 2>>"$LOG_FILE" | \
        nc "$SIMUL_HOST" "$SIMUL_PORT" | while read -r line; do
        if is_key_pressed && [[ -n "$line" ]]; then
            # Remove timing numbers at start (e.g., "0 3320  Hello" -> "Hello")
            # Pattern: one or more digits, space, one or more digits, then the text
            clean_line=$(echo "$line" | sed 's/^[0-9][0-9]* [0-9][0-9]* *//')
            # Remove extra spaces and spaces before punctuation
            clean_line=$(echo "$clean_line" | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*\([.,!?;:]\)/\1/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$clean_line" ]]; then
                # Add leading space unless it's punctuation
                local punct_re='^[.,!?;:]'
                if [[ ! "$clean_line" =~ $punct_re ]]; then
                    xdotool type " "
                fi
                xdotool type -- "$clean_line"
            fi
        fi
    done
}

# Main function
main() {
    echo "Starting SimulStreaming Push-to-Talk Dictation Tool..."
    check_dependencies
    > "$LOG_FILE"

    start_server

    echo "Press and hold key $KEYCODE to dictate..."

    monitor_key &
    process_simul_output
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
