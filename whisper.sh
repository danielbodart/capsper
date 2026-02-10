#!/bin/bash

# SimulStreaming Push-to-Talk Dictation Tool
# Uses SimulStreaming server for speech recognition

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
SIMUL_DIR="$SCRIPT_DIR/SimulStreaming"
SIMUL_SERVER="simulstreaming_whisper_server.py"
SIMUL_HOST="localhost"
SIMUL_PORT=43007
LOG_FILE="/tmp/whisper-dictation.log"
KEY_STATE_FILE="/tmp/key_state"

# Detect display server and set input backend
# Override with WHISPER_BACKEND=x11 or WHISPER_BACKEND=wayland
INPUT_BACKEND="${WHISPER_BACKEND:-}"
if [[ -z "$INPUT_BACKEND" ]]; then
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        INPUT_BACKEND="wayland"
    else
        INPUT_BACKEND="x11"
    fi
fi

# Backend-specific config
if [[ "$INPUT_BACKEND" == "wayland" ]]; then
    EVDEV_KEYCODE=194  # KEY_F24 in evdev
    KEYBOARD_DEVICE=""  # auto-detected
else
    XINPUT_KEYCODE=202  # F24 in X11
    KEYBOARD_DEVICE_ID="${WHISPER_KEYBOARD_ID:-12}"
fi

# PIDs for cleanup
SERVER_PID=""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    jobs -p | xargs -r kill 2>/dev/null || true
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -f "$KEY_STATE_FILE" ]] && rm -f "$KEY_STATE_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Check dependencies
check_dependencies() {
    local missing_deps=()

    if [[ "$INPUT_BACKEND" == "wayland" ]]; then
        command -v evtest >/dev/null || missing_deps+=("evtest")
        command -v ydotool >/dev/null || missing_deps+=("ydotool")
    else
        command -v xinput >/dev/null || missing_deps+=("xinput")
        command -v xdotool >/dev/null || missing_deps+=("xdotool")
    fi
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

# Auto-detect keyboard device for evtest
detect_keyboard() {
    # If keyd is running, monitor its virtual keyboard (it emits the remapped keys)
    local keyd_event
    keyd_event=$(grep -A 4 "keyd virtual keyboard" /proc/bus/input/devices 2>/dev/null | grep -o 'event[0-9]\+' || true)
    if [[ -n "$keyd_event" ]]; then
        KEYBOARD_DEVICE="/dev/input/$keyd_event"
        echo "Detected keyd virtual keyboard: $KEYBOARD_DEVICE"
        return
    fi

    # Otherwise find the physical keyboard (EV=120013 = EV_SYN + EV_KEY + EV_MSC + EV_LED + EV_REP)
    local phys_event
    phys_event=$(grep -B 5 'EV=120013' /proc/bus/input/devices | grep -o 'event[0-9]\+' | head -1 || true)
    if [[ -n "$phys_event" ]]; then
        KEYBOARD_DEVICE="/dev/input/$phys_event"
        echo "Detected keyboard: $KEYBOARD_DEVICE"
        return
    fi

    echo "ERROR: Could not auto-detect keyboard device" >&2
    echo "Set KEYBOARD_DEVICE manually in the script" >&2
    exit 1
}

# Start the SimulStreaming server
start_server() {
    echo "Starting SimulStreaming server..."
    (cd "$SIMUL_DIR" && mise exec -- python3 "$SIMUL_SERVER" --vac --out-txt --warmup-file "$SCRIPT_DIR/jfk.wav" --model_path ./large-v3-turbo.pt) >> "$LOG_FILE" 2>&1 &
    SERVER_PID=$!

    # Wait for server to be listening (up to 5 minutes for first-time model download)
    echo "Waiting for server to load model and start listening..."
    local max_wait=300
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
    echo "0" > "$KEY_STATE_FILE"
    local debounce_pid=""

    delayed_release() {
        sleep 1
        echo "0" > "$KEY_STATE_FILE"
        echo "Key released"
    }

    if [[ "$INPUT_BACKEND" == "wayland" ]]; then
        echo "Monitoring KEY_F24 (evdev $EVDEV_KEYCODE) on $KEYBOARD_DEVICE"

        # evtest output: "Event: time ..., type 1 (EV_KEY), code 194 (KEY_F24), value 1"
        evtest "$KEYBOARD_DEVICE" 2>/dev/null | grep --line-buffered "code $EVDEV_KEYCODE" | while read -r line; do
            if [[ "$line" =~ value\ 1$ ]]; then
                [[ -n "$debounce_pid" ]] && kill "$debounce_pid" 2>/dev/null || true
                debounce_pid=""
                if [[ "$(cat "$KEY_STATE_FILE" 2>/dev/null)" == "0" ]]; then
                    echo "1" > "$KEY_STATE_FILE"
                    echo "Key pressed"
                fi
            elif [[ "$line" =~ value\ 0$ ]]; then
                [[ -n "$debounce_pid" ]] && kill "$debounce_pid" 2>/dev/null || true
                delayed_release &
                debounce_pid=$!
            fi
        done
    else
        local device_name
        device_name=$(xinput list | grep "id=$KEYBOARD_DEVICE_ID" | sed 's/.*↳[[:space:]]*//' | sed 's/[[:space:]]*id=.*//')
        echo "Monitoring key $XINPUT_KEYCODE on device: $device_name (ID: $KEYBOARD_DEVICE_ID)"

        xinput test "$KEYBOARD_DEVICE_ID" | while read -r line; do
            if [[ "$line" =~ key\ press\ +$XINPUT_KEYCODE ]]; then
                [[ -n "$debounce_pid" ]] && kill "$debounce_pid" 2>/dev/null || true
                debounce_pid=""
                if [[ "$(cat "$KEY_STATE_FILE" 2>/dev/null)" == "0" ]]; then
                    echo "1" > "$KEY_STATE_FILE"
                    echo "Key pressed"
                fi
            elif [[ "$line" =~ key\ release\ +$XINPUT_KEYCODE ]]; then
                [[ -n "$debounce_pid" ]] && kill "$debounce_pid" 2>/dev/null || true
                delayed_release &
                debounce_pid=$!
            fi
        done
    fi
}

# Check if key is pressed
is_key_pressed() {
    [[ -f "$KEY_STATE_FILE" ]] && [[ "$(cat "$KEY_STATE_FILE" 2>/dev/null)" == "1" ]]
}

# Type text into the focused window
type_text() {
    if [[ "$INPUT_BACKEND" == "wayland" ]]; then
        ydotool type -- "$@"
    else
        xdotool type -- "$@"
    fi
}

# Process SimulStreaming output
process_simul_output() {
    arecord -f S16_LE -c1 -r 16000 -t raw -D default 2>>"$LOG_FILE" | \
        nc "$SIMUL_HOST" "$SIMUL_PORT" | while read -r line; do
        if is_key_pressed && [[ -n "$line" ]]; then
            # Remove timing numbers at start (e.g., "0 3320  Hello" -> "Hello")
            clean_line=$(echo "$line" | sed 's/^[0-9][0-9]* [0-9][0-9]* *//')
            # Remove extra spaces and spaces before punctuation
            clean_line=$(echo "$clean_line" | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*\([.,!?;:]\)/\1/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$clean_line" ]]; then
                local punct_re='^[.,!?;:]'
                if [[ ! "$clean_line" =~ $punct_re ]]; then
                    type_text " "
                fi
                type_text "$clean_line"
            fi
        fi
    done
}

# Main function
main() {
    echo "Starting SimulStreaming Push-to-Talk Dictation Tool ($INPUT_BACKEND backend)..."
    check_dependencies
    > "$LOG_FILE"

    if [[ "$INPUT_BACKEND" == "wayland" ]]; then
        detect_keyboard
    fi

    start_server

    echo "Press and hold F24 to dictate..."

    monitor_key &
    process_simul_output
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
