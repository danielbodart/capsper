#!/bin/bash
# Send a WAV file to the whisper server at real-time rate (simulating a microphone).
# Starts its own server on an OS-assigned port, cleans up on exit.
#
# Usage: ./test-stream.sh [file.wav]

set -euo pipefail

WAV="${1:-jfk.wav}"
BINARY="./zig-out/bin/whisper-dictate"

if [ ! -x "$BINARY" ]; then
    echo "Binary not found: $BINARY (run: mise exec zig -- zig build)" >&2
    exit 1
fi
if [ ! -f "$WAV" ]; then
    echo "File not found: $WAV" >&2
    exit 1
fi

# Start server on OS-assigned port
SERVER_LOG=$(mktemp /tmp/whisper-server-XXXXXX.log)
"$BINARY" --port 0 > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    rm -f "$SERVER_LOG"
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

echo "Streaming $WAV to localhost:$PORT at real-time rate..." >&2

# Skip 44-byte WAV header, send at 32000 bytes/sec (16kHz S16 mono)
tail -c +45 "$WAV" | pv -qL 32000 | nc -q 5 localhost "$PORT"
