#!/bin/bash
# Long streaming test: loops jfk.wav PCM data 20 times as a continuous stream.
# Sends at real-time rate (32000 bytes/sec = 16kHz S16 mono).
# Total duration: ~220 seconds (~3.7 minutes).
# Starts its own server on an OS-assigned port, cleans up on exit.
#
# Usage: ./test-long-stream.sh
#
# The server should keep emitting text throughout. If it goes silent after
# ~50 words, the sliding window / emitted_words tracking is broken.

set -euo pipefail

BINARY="./zig-out/bin/whisper-dictate"
WAV="jfk.wav"
LOOPS=20

if [ ! -x "$BINARY" ]; then
    echo "Binary not found: $BINARY (run: mise exec zig -- zig build)" >&2
    exit 1
fi
if [ ! -f "$WAV" ]; then
    echo "File not found: $WAV" >&2
    exit 1
fi

# Extract raw PCM (skip 44-byte WAV header)
RAW_PCM=$(mktemp /tmp/whisper-test-XXXXXX.raw)

# Start server on OS-assigned port
SERVER_LOG=$(mktemp /tmp/whisper-server-XXXXXX.log)
"$BINARY" --port 0 > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    rm -f "$RAW_PCM" "$SERVER_LOG"
}
trap cleanup EXIT

# Wait for server to print its port
echo "Starting server (PID $SERVER_PID)..." >&2
for i in $(seq 1 60); do
    if grep -q "Listening on port" "$SERVER_LOG" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Server died during startup. Log:" >&2
        cat "$SERVER_LOG" >&2
        exit 1
    fi
    sleep 1
done

PORT=$(grep -oP 'Listening on port \K[0-9]+' "$SERVER_LOG" 2>/dev/null || true)
if [ -z "$PORT" ]; then
    echo "Server failed to start within 60s. Log:" >&2
    tail -20 "$SERVER_LOG" >&2
    exit 1
fi

tail -c +45 "$WAV" > "$RAW_PCM"
RAW_SIZE=$(stat -c %s "$RAW_PCM")
DURATION_PER_LOOP=$(echo "scale=1; $RAW_SIZE / 32000" | bc)
TOTAL_DURATION=$(echo "scale=1; $DURATION_PER_LOOP * $LOOPS" | bc)

echo "Raw PCM: $RAW_SIZE bytes per loop ($DURATION_PER_LOOP s)" >&2
echo "Streaming $LOOPS loops = ${TOTAL_DURATION}s to localhost:$PORT" >&2
echo "---" >&2

# Concatenate N loops of raw PCM into a continuous stream, pipe at real-time rate
(for i in $(seq 1 $LOOPS); do cat "$RAW_PCM"; done) \
    | pv -qL 32000 \
    | nc -q 5 localhost "$PORT" \
    | while IFS= read -r line; do
        echo "$line"
    done

echo "---" >&2
echo "Done." >&2
