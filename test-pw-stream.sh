#!/bin/bash
# Send a WAV file through PipeWire to the whisper server at real-time rate.
# Uses pw-loopback to create a virtual sink+source bridge, then pw-cat to play
# audio into the sink while the server captures from the source.
#
# This is the PipeWire equivalent of test-stream.sh (which uses TCP + pv).
#
# Usage: ./test-pw-stream.sh [file.wav]
#
# Requires: pw-loopback, pw-cat, pactl (from pipewire and pipewire-pulse)

set -euo pipefail

WAV="${1:-jfk.wav}"
BINARY="./zig-out/bin/whisper-dictate"
LOOPBACK_SINK="test-whisper-loopback-sink"
LOOPBACK_SOURCE="test-whisper-loopback-source"

if [ ! -x "$BINARY" ]; then
    echo "Binary not found: $BINARY (run: mise exec zig -- zig build)" >&2
    exit 1
fi
if [ ! -f "$WAV" ]; then
    echo "File not found: $WAV" >&2
    exit 1
fi

RAW_SIZE=$(( $(stat -c %s "$WAV") - 44 ))
DURATION=$(echo "scale=1; $RAW_SIZE / 32000" | bc)

SERVER_LOG=$(mktemp /tmp/whisper-server-XXXXXX.log)
STREAM_OUTPUT=$(mktemp /tmp/whisper-pw-stream-XXXXXX.txt)

cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    [ -n "${LOOPBACK_PID:-}" ] && kill "$LOOPBACK_PID" 2>/dev/null
    [ -n "${PWCAT_PID:-}" ] && kill "$PWCAT_PID" 2>/dev/null
    wait 2>/dev/null || true
    rm -f "$SERVER_LOG" "$STREAM_OUTPUT"
}
trap cleanup EXIT

# 1. Start pw-loopback: creates a virtual sink + source bridge
pw-loopback \
    --capture-props="media.class=Audio/Sink node.name=$LOOPBACK_SINK" \
    --playback-props="media.class=Audio/Source node.name=$LOOPBACK_SOURCE" \
    -C 1 -m MONO &
LOOPBACK_PID=$!
sleep 1

# Verify loopback created both nodes
if ! pw-link -o 2>/dev/null | grep -q "$LOOPBACK_SOURCE"; then
    echo "Failed to create PipeWire loopback. Is PipeWire running?" >&2
    exit 1
fi

# 2. Start server in local PipeWire capture mode
"$BINARY" --input local \
    --pw-target "$LOOPBACK_SOURCE" \
    --pw-channel MONO \
    > "$STREAM_OUTPUT" 2> "$SERVER_LOG" &
SERVER_PID=$!

echo "Starting server (PID $SERVER_PID)..." >&2
for i in $(seq 1 60); do
    if grep -q "Capturing audio" "$SERVER_LOG" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Server died during startup. Log:" >&2
        cat "$SERVER_LOG" >&2
        exit 1
    fi
    sleep 1
done

if ! grep -q "Capturing audio" "$SERVER_LOG" 2>/dev/null; then
    echo "Server failed to start within 60s. Log:" >&2
    tail -20 "$SERVER_LOG" >&2
    exit 1
fi

echo "Streaming $WAV ($DURATION s) via PipeWire..." >&2

# 3. Play WAV through the loopback sink (pw-cat handles real-time pacing)
pw-cat -p \
    --target="$LOOPBACK_SINK" \
    --rate=16000 --channels=1 --format=s16 \
    "$WAV" &
PWCAT_PID=$!

# Wait for playback to finish
wait "$PWCAT_PID" 2>/dev/null
PWCAT_PID=""

# Give the server time to flush trailing transcription
sleep 3

# 4. Show results
echo "" >&2
echo "=== Streaming Output ===" >&2
cat "$STREAM_OUTPUT" >&2

WORD_COUNT=$(cut -f2- "$STREAM_OUTPUT" | wc -w)
echo "" >&2
echo "Total words emitted: $WORD_COUNT" >&2
