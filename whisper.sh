#!/bin/bash

# Whisper Push-to-Talk Dictation Tool
# Uses whisper-dictate server for speech recognition

set -uo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
SERVER_BIN="$SCRIPT_DIR/zig-out/bin/whisper-dictate"
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
    KEYBOARD_DEVICE_ID="${WHISPER_KEYBOARD_ID:-}"  # auto-detected if empty
fi

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    trap '' SIGINT SIGTERM  # ignore signals so we can finish cleanup
    # Kill our entire process group (server, xinput, etc.)
    kill -- -$$ 2>/dev/null || true
    rm -f "$KEY_STATE_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Check dependencies
check_dependencies() {
    local missing_deps=()

    if [[ "$INPUT_BACKEND" == "wayland" ]]; then
        command -v evtest >/dev/null || missing_deps+=("evtest")
        command -v ydotool >/dev/null || missing_deps+=("ydotool")
        if [[ ! -S /tmp/.ydotool_socket ]]; then
            echo "ERROR: ydotoold socket not found at /tmp/.ydotool_socket" >&2
            echo "Start it with: systemctl --user start ydotoold" >&2
            echo "Or run ./run.ts setup to set it up automatically." >&2
            exit 1
        fi
    else
        command -v xinput >/dev/null || missing_deps+=("xinput")
        command -v xdotool >/dev/null || missing_deps+=("xdotool")
    fi
    [[ -f "$SERVER_BIN" ]] || missing_deps+=("whisper-dictate binary (run: ./run.ts)")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing_deps[*]}" >&2
        exit 1
    fi
}

# Auto-detect keyboard device
detect_keyboard() {
    if [[ "$INPUT_BACKEND" == "wayland" ]]; then
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
    else
        # X11: use override if set, otherwise auto-detect
        if [[ -n "$KEYBOARD_DEVICE_ID" ]]; then
            echo "Using keyboard device ID: $KEYBOARD_DEVICE_ID (from WHISPER_KEYBOARD_ID)"
            return
        fi

        # Auto-detect: find the keyboard name from /proc/bus/input/devices,
        # then match it to an xinput device ID.
        # Check keyd virtual keyboard first, then physical keyboard (EV=120013)
        local kb_name=""
        local block=""
        while IFS= read -r line || [[ -n "$block" ]]; do
            if [[ -z "$line" ]]; then
                if [[ -n "$kb_name" ]]; then
                    break
                fi
                if [[ "$block" == *"keyd virtual keyboard"* ]]; then
                    kb_name=$(echo "$block" | grep -o 'N: Name="[^"]*"' | sed 's/N: Name="//;s/"//')
                elif [[ "$block" == *"EV=120013"* ]] && [[ -z "$kb_name" ]]; then
                    kb_name=$(echo "$block" | grep -o 'N: Name="[^"]*"' | sed 's/N: Name="//;s/"//')
                fi
                block=""
            else
                block="$block"$'\n'"$line"
            fi
        done < /proc/bus/input/devices

        if [[ -n "$kb_name" ]]; then
            # Match the kernel device name to an xinput device ID
            while read -r dev_line; do
                local dev_name dev_id
                dev_name=$(echo "$dev_line" | sed 's/.*↳[[:space:]]*//' | sed 's/[[:space:]]*id=.*//')
                dev_id=$(echo "$dev_line" | grep -o 'id=[0-9]\+' | cut -d= -f2)
                if [[ "$dev_name" == "$kb_name" ]]; then
                    KEYBOARD_DEVICE_ID="$dev_id"
                    echo "Detected keyboard: $kb_name (xinput id=$dev_id)"
                    return
                fi
            done < <(xinput list | grep 'slave  keyboard')
        fi

        # Fallback: monitor all slave keyboard devices
        mapfile -t _ALL_KEYBOARD_IDS < <(xinput list | grep 'slave  keyboard' | grep -o 'id=[0-9]\+' | cut -d= -f2)
        if [[ ${#_ALL_KEYBOARD_IDS[@]} -eq 0 ]]; then
            echo "ERROR: No X11 keyboard devices found" >&2
            exit 1
        fi
        KEYBOARD_DEVICE_ID="${_ALL_KEYBOARD_IDS[0]}"
        echo "WARNING: Could not auto-detect keyboard, using first device (id=$KEYBOARD_DEVICE_ID)" >&2
    fi
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
        while read -r line; do
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
        done < <(evtest "$KEYBOARD_DEVICE" 2>/dev/null | grep --line-buffered "code $EVDEV_KEYCODE")
    else
        echo "Monitoring F24 (keycode $XINPUT_KEYCODE) on xinput device $KEYBOARD_DEVICE_ID"

        while true; do
            while read -r line; do
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
            done < <(xinput test "$KEYBOARD_DEVICE_ID" 2>/dev/null)
            echo "Key monitor disconnected, reconnecting in 2s..."
            sleep 2
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

# Process server output (local PipeWire capture mode)
process_output() {
    while true; do
        "$SERVER_BIN" --input local \
            --pw-channel "${WHISPER_PW_CHANNEL:-AUX2}" \
            ${WHISPER_PW_TARGET:+--pw-target "$WHISPER_PW_TARGET"} \
            2>>"$LOG_FILE" | while read -r line; do
            if is_key_pressed && [[ -n "$line" ]]; then
                # Strip timestamp prefix (e.g. "2.3\ttext" → "text")
                line="${line#*$'\t'}"
                # Server sends clean text — just normalize whitespace and punctuation spacing
                clean_line=$(echo "$line" | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*\([.,!?;:]\)/\1/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [[ -n "$clean_line" ]]; then
                    local punct_re='^[.,!?;:]'
                    if [[ ! "$clean_line" =~ $punct_re ]]; then
                        type_text " "
                    fi
                    type_text "$clean_line"
                fi
            fi
        done
        echo "Server exited, restarting in 2s..."
        sleep 2
    done
}

# Main function
main() {
    echo "Starting Whisper Push-to-Talk Dictation ($INPUT_BACKEND backend)..."
    check_dependencies
    > "$LOG_FILE"

    detect_keyboard

    echo "Press and hold F24 to dictate..."
    echo "Audio: PipeWire local capture (channel=${WHISPER_PW_CHANNEL:-AUX2})"

    monitor_key &
    process_output
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
