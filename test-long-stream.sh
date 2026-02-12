#!/bin/bash
# Long streaming test: loops jfk.wav PCM data 20 times as a continuous stream.
# Sends at real-time rate (32000 bytes/sec = 16kHz S16 mono).
# Total duration: ~220 seconds (~3.7 minutes).
#
# Usage: ./test-long-stream.sh [port]
#
# The server should keep emitting text throughout. If it goes silent after
# ~50 words, the sliding window / emitted_words tracking is broken.

PORT="${1:-43007}"
WAV="jfk.wav"
LOOPS=20

if [ ! -f "$WAV" ]; then
    echo "File not found: $WAV" >&2
    exit 1
fi

# Extract raw PCM (skip 44-byte WAV header)
RAW_PCM=$(mktemp /tmp/whisper-test-XXXXXX.raw)
trap 'rm -f "$RAW_PCM"' EXIT

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
