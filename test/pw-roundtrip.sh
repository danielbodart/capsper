#!/usr/bin/env bash
# Play a WAV file through a PipeWire loopback and record the output.
# Usage: ./test/pw-roundtrip.sh test/jfk.wav [output.wav]
#
# This creates a loopback pair (sink + source), plays the input WAV through
# the sink, and records from the source into the output WAV. Compare the
# input and output to hear what PipeWire resampling does to the audio.

set -euo pipefail

INPUT="${1:?Usage: $0 <input.wav> [output.wav]}"
OUTPUT="${2:-${INPUT%.wav}-pw-roundtrip.wav}"

SINK_NAME="roundtrip-test-sink"
SOURCE_NAME="roundtrip-test-source"

cleanup() {
    kill "$LOOPBACK_PID" 2>/dev/null || true
    kill "$RECORD_PID" 2>/dev/null || true
    wait "$LOOPBACK_PID" 2>/dev/null || true
    wait "$RECORD_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "Input:  $INPUT"
echo "Output: $OUTPUT"

# Get audio duration for recording timeout
DURATION=$(soxi -D "$INPUT" 2>/dev/null || python3 -c "
import struct, sys
with open('$INPUT', 'rb') as f:
    f.read(44)
    data = f.read()
    print(len(data) / 32000)
")
echo "Duration: ${DURATION}s"

# Create loopback — try with audio.rate=16000 to avoid resampling
echo "Creating PipeWire loopback (16kHz mono)..."
pw-loopback \
    --capture-props="{\"media.class\":\"Audio/Sink\", \"node.name\":\"${SINK_NAME}\", \"audio.rate\":16000}" \
    --playback-props="{\"media.class\":\"Audio/Source\", \"node.name\":\"${SOURCE_NAME}\", \"audio.rate\":16000}" \
    -C 1 -m MONO &
LOOPBACK_PID=$!
sleep 0.5

# Start recording from the loopback source
echo "Starting recording..."
pw-cat -r --target="${SOURCE_NAME}" --rate=16000 --channels=1 --format=s16 "$OUTPUT" &
RECORD_PID=$!
sleep 0.3

# Play the input WAV through the loopback sink
echo "Playing through loopback..."
pw-cat -p --target="${SINK_NAME}" --rate=16000 --channels=1 --format=s16 "$INPUT"

# Wait a bit for any latent audio, then stop recording
echo "Playback done, waiting for tail..."
sleep 0.5
kill "$RECORD_PID" 2>/dev/null || true
wait "$RECORD_PID" 2>/dev/null || true

echo ""
echo "=== Results ==="
echo "Input:  $INPUT ($(stat -c%s "$INPUT") bytes)"
echo "Output: $OUTPUT ($(stat -c%s "$OUTPUT") bytes)"

# Compare PCM byte-for-byte
python3 -c "
import sys

def read_pcm(path):
    with open(path, 'rb') as f:
        f.read(44)  # skip WAV header
        return f.read()

inp = read_pcm('$INPUT')
out = read_pcm('$OUTPUT')

print(f'Input PCM:  {len(inp)} bytes ({len(inp)/32000:.2f}s)')
print(f'Output PCM: {len(out)} bytes ({len(out)/32000:.2f}s)')

# Compare overlap
overlap = min(len(inp), len(out))
diffs = 0
max_diff = 0
for i in range(0, overlap, 2):
    a = int.from_bytes(inp[i:i+2], 'little', signed=True)
    b = int.from_bytes(out[i:i+2], 'little', signed=True)
    d = abs(a - b)
    if d > 0:
        diffs += 1
        max_diff = max(max_diff, d)

total_samples = overlap // 2
print(f'Samples compared: {total_samples}')
print(f'Differing samples: {diffs} ({diffs*100/total_samples:.1f}%)')
print(f'Max sample difference: {max_diff}')
if diffs == 0:
    print('IDENTICAL — PipeWire loopback preserved audio perfectly!')
else:
    # Compute RMS of the difference
    rms_sum = 0
    for i in range(0, overlap, 2):
        a = int.from_bytes(inp[i:i+2], 'little', signed=True)
        b = int.from_bytes(out[i:i+2], 'little', signed=True)
        rms_sum += (a - b) ** 2
    rms = (rms_sum / total_samples) ** 0.5
    print(f'RMS difference: {rms:.1f} (out of 32768 full scale)')
    print(f'SNR: {20 * __import__(\"math\").log10(32768 / max(rms, 1e-10)):.1f} dB')
"

echo ""
echo "Listen to both files to compare:"
echo "  play $INPUT"
echo "  play $OUTPUT"
