#!/bin/bash
# Stream a WAV file and compare streaming output against a reference transcript.
# Reports word coverage, missed words, and timing.
#
# Usage: ./test-compare.sh
#
# Requires: testdata/long-recording.wav and testdata/long-recording.txt

set -euo pipefail

BINARY="./zig-out/bin/whisper-dictate"
WAV="testdata/long-recording.wav"
REF="testdata/long-recording.txt"

if [ ! -x "$BINARY" ]; then
    echo "Binary not found: $BINARY (run: mise exec zig -- zig build)" >&2
    exit 1
fi
if [ ! -f "$WAV" ]; then
    echo "File not found: $WAV" >&2
    exit 1
fi
if [ ! -f "$REF" ]; then
    echo "Reference transcript not found: $REF" >&2
    exit 1
fi

RAW_SIZE=$(( $(stat -c %s "$WAV") - 44 ))
DURATION=$(echo "scale=1; $RAW_SIZE / 32000" | bc)

# Start server on OS-assigned port
SERVER_LOG=$(mktemp /tmp/whisper-server-XXXXXX.log)
"$BINARY" --port 0 > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
    rm -f "$STREAM_OUTPUT" "$SERVER_LOG"
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

echo "=== Streaming Comparison Test ===" >&2
echo "Audio: $WAV ($DURATION s)" >&2
echo "Reference: $REF" >&2
echo "Server: localhost:$PORT" >&2
echo "" >&2

# Capture streaming output
STREAM_OUTPUT=$(mktemp /tmp/whisper-compare-XXXXXX.txt)

echo "Streaming at real-time rate..." >&2
tail -c +45 "$WAV" | pv -qL 32000 | nc -q 5 localhost "$PORT" > "$STREAM_OUTPUT"

echo "" >&2
echo "=== Raw Streaming Output ===" >&2
cat "$STREAM_OUTPUT" >&2

# Extract just the text (strip timestamp prefix), join into single line
STREAM_TEXT=$(cut -f2- "$STREAM_OUTPUT" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

# Normalize both texts: lowercase, strip punctuation, collapse whitespace
normalize() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed "s/[^a-z0-9' ]/ /g" | sed 's/  */ /g; s/^ *//; s/ *$//'
}

NORM_REF=$(normalize "$(cat "$REF")")
NORM_STREAM=$(normalize "$STREAM_TEXT")

# Split into word arrays
read -ra REF_WORDS <<< "$NORM_REF"
read -ra STREAM_WORDS <<< "$NORM_STREAM"

REF_COUNT=${#REF_WORDS[@]}
STREAM_COUNT=${#STREAM_WORDS[@]}

echo "" >&2
echo "=== Word Comparison ===" >&2
echo "Reference words: $REF_COUNT" >&2
echo "Streamed words:  $STREAM_COUNT" >&2

# Find longest common subsequence length using a greedy forward match
# (not true LCS, but a good-enough ordered match for this purpose)
matched=0
stream_idx=0
missed_words=()
for (( r=0; r<REF_COUNT; r++ )); do
    found=false
    # Look ahead up to 5 positions for a match (handles minor insertions in stream)
    for (( look=0; look<5 && stream_idx+look<STREAM_COUNT; look++ )); do
        if [[ "${REF_WORDS[$r]}" == "${STREAM_WORDS[$((stream_idx+look))]}" ]]; then
            matched=$((matched + 1))
            stream_idx=$((stream_idx + look + 1))
            found=true
            break
        fi
    done
    if ! $found; then
        missed_words+=("${REF_WORDS[$r]}")
    fi
done

if [ "$REF_COUNT" -gt 0 ]; then
    coverage=$(echo "scale=1; $matched * 100 / $REF_COUNT" | bc)
else
    coverage="0"
fi

echo "" >&2
echo "=== Results ===" >&2
echo "Matched: $matched / $REF_COUNT words ($coverage%)" >&2
echo "Missed:  ${#missed_words[@]} words" >&2

if [ ${#missed_words[@]} -gt 0 ]; then
    echo "" >&2
    echo "Missed words:" >&2
    printf '  %s\n' "${missed_words[@]}" >&2
fi

# Show timing of emissions
echo "" >&2
echo "=== Emission Timeline ===" >&2
while IFS=$'\t' read -r timestamp text; do
    word_count=$(echo "$text" | wc -w)
    echo "  ${timestamp}s  (+${word_count}w)  $text" >&2
done < "$STREAM_OUTPUT"

echo "" >&2
echo "=== Summary ===" >&2
echo "Coverage: $coverage% ($matched/$REF_COUNT)" >&2
echo "Duration: ${DURATION}s" >&2

# Also output machine-readable summary to stdout
echo "$matched/$REF_COUNT $coverage%"
