#!/bin/bash
# Send a WAV file to the whisper server at real-time rate (simulating a microphone).
# Usage: ./test-stream.sh [file.wav] [port]
WAV="${1:-jfk.wav}"
PORT="${2:-43008}"

if [ ! -f "$WAV" ]; then
    echo "File not found: $WAV" >&2
    exit 1
fi

echo "Streaming $WAV to localhost:$PORT at real-time rate..." >&2

# Skip 44-byte WAV header, send at 32000 bytes/sec (16kHz S16 mono)
tail -c +45 "$WAV" | pv -qL 32000 | nc -q 5 localhost "$PORT"
