#!/usr/bin/env bash
set -euo pipefail

# Self-contained installer for zigsper.
# Ships in the dist tarball alongside the binary and shared libs.
#
# Usage:
#   ./install.sh              Full interactive setup (download models, permissions, systemd)
#   ./install.sh pw-detect    Detect best PipeWire microphone channel
#   ./install.sh setup-dev DIR  Developer mode: permissions + pw-detect + systemd (called by run.ts)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WHISPER_MODEL_NAME="ggml-large-v3-turbo-q5_0.bin"
VAD_MODEL_NAME="ggml-silero-v5.1.2.bin"
WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_MODEL_NAME}"
VAD_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${VAD_MODEL_NAME}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    printf '%s [Y/n] ' "$prompt"
    read -r answer
    case "${answer,,}" in
        ""|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

# ─── Permissions ──────────────────────────────────────────────────────────────

check_permissions() {
    # Check input group membership
    if ! id -nG | grep -qw input; then
        echo ""
        echo "=== Permissions Setup ==="
        echo "The 'input' group is needed for keyboard grab and text injection."
        if confirm "Add current user to 'input' group? (requires sudo)"; then
            sudo usermod -aG input "$USER"
            echo "Added to 'input' group. You may need to log out and back in."
        fi
    fi

    # Check /dev/uinput access
    local uinput_rule='/etc/udev/rules.d/99-uinput.rules'
    if [ ! -f "$uinput_rule" ]; then
        echo ""
        echo "Setting up /dev/uinput access..."
        if confirm "Install udev rule for /dev/uinput? (requires sudo)"; then
            echo 'KERNEL=="uinput", MODE="0660", GROUP="input"' | sudo tee "$uinput_rule" >/dev/null
            sudo udevadm control --reload-rules || true
            sudo udevadm trigger /dev/uinput || true
            echo "udev rule installed."
        fi
    fi
}

# ─── Model Download ──────────────────────────────────────────────────────────

download_models() {
    local model_dir="$1"
    mkdir -p "$model_dir"
    local missing=()

    [ -f "$model_dir/$WHISPER_MODEL_NAME" ] || missing+=("Whisper model (large-v3-turbo-q5_0, ~574 MB)")
    [ -f "$model_dir/$VAD_MODEL_NAME" ] || missing+=("VAD model (silero-v5.1.2, ~2 MB)")

    if [ ${#missing[@]} -eq 0 ]; then
        echo "Models already present."
        return
    fi

    echo "Missing models:"
    for m in "${missing[@]}"; do echo "  - $m"; done

    if ! confirm "Download now?"; then
        die "Models required. Download manually into $model_dir/"
    fi

    require_cmd curl "Install curl to download models."

    if [ ! -f "$model_dir/$WHISPER_MODEL_NAME" ]; then
        echo "Downloading Whisper model..."
        curl -L --progress-bar -o "$model_dir/$WHISPER_MODEL_NAME" "$WHISPER_MODEL_URL"
    fi
    if [ ! -f "$model_dir/$VAD_MODEL_NAME" ]; then
        echo "Downloading VAD model..."
        curl -L --progress-bar -o "$model_dir/$VAD_MODEL_NAME" "$VAD_MODEL_URL"
    fi

    echo "Models downloaded."
}

# ─── PipeWire Channel Detection ──────────────────────────────────────────────

pw_detect() {
    local target="${1:-}"
    local duration="${2:-5}"

    require_cmd pw-record "Install PipeWire."

    local sample_rate=48000
    local format="s32"
    local target_args=()
    [ -n "$target" ] && target_args=(--target "$target")

    if [ -n "$target" ]; then
        echo "Probing device: $target"
    else
        echo "Probing default audio source..."
    fi
    echo "Recording duration: ${duration}s per phase"
    echo ""

    # Record silence
    read -rp "Press ENTER to start recording SILENCE (stay quiet)..."
    echo "Recording ${duration}s of silence..."
    local silence_file
    silence_file=$(mktemp /tmp/pw-detect-silence-XXXXXX.wav)
    pw-record --rate="$sample_rate" --format="$format" "${target_args[@]}" "$silence_file" &
    local silence_pid=$!
    sleep "$duration"
    kill "$silence_pid" 2>/dev/null; wait "$silence_pid" 2>/dev/null || true
    echo "Done."
    echo ""

    # Parse WAV header for channel count and bit depth
    local num_channels bits_per_sample
    num_channels=$(od -An -tu2 -j22 -N2 "$silence_file" | tr -d ' ')
    bits_per_sample=$(od -An -tu2 -j34 -N2 "$silence_file" | tr -d ' ')
    local bytes_per_sample=$((bits_per_sample / 8))

    echo "  Channels: $num_channels, Format: S${bits_per_sample}LE, Rate: ${sample_rate}Hz"
    echo ""

    # Record speech
    read -rp "Press ENTER to start recording SPEECH (talk normally)..."
    echo "Recording ${duration}s of speech..."
    local speech_file
    speech_file=$(mktemp /tmp/pw-detect-speech-XXXXXX.wav)
    pw-record --rate="$sample_rate" --format="$format" "${target_args[@]}" "$speech_file" &
    local speech_pid=$!
    sleep "$duration"
    kill "$speech_pid" 2>/dev/null; wait "$speech_pid" 2>/dev/null || true
    echo "Done."
    echo ""

    # Use python3 for RMS computation (available on virtually all Linux systems)
    require_cmd python3 "Install python3 for audio analysis."

    local result
    result=$(python3 -c "
import struct, sys, math

def parse_wav(path):
    with open(path, 'rb') as f:
        data = f.read()
    nc = struct.unpack_from('<H', data, 22)[0]
    bps = struct.unpack_from('<H', data, 34)[0]
    # Find data chunk
    off = 12
    while off + 8 < len(data):
        cid = data[off:off+4]
        csz = struct.unpack_from('<I', data, off+4)[0]
        off += 8
        if cid == b'data':
            return nc, bps, data[off:off+csz]
        off += csz
    return nc, bps, b''

def channel_rms(pcm, nc, bps, ch):
    fmt = {1: 'b', 2: '<h', 4: '<i'}[bps]
    scale = {1: 128, 2: 32768, 4: 2147483648}[bps]
    frame_size = nc * bps
    n = len(pcm) // frame_size
    sum_sq = 0.0
    for i in range(n):
        off = i * frame_size + ch * bps
        val = struct.unpack_from(fmt, pcm, off)[0]
        norm = val / scale
        sum_sq += norm * norm
    return math.sqrt(sum_sq / max(n, 1))

def rms_to_db(rms):
    return 20 * math.log10(rms) if rms > 1e-10 else -100

nc1, bps1, pcm_silence = parse_wav('$silence_file')
nc2, bps2, pcm_speech = parse_wav('$speech_file')

nc = nc1
bps = bps1

print('=== Channel Analysis ===')
print()
print('  Channel   | Silence (dB) | Speech (dB)  | Delta (dB)')
print('  ----------|--------------|--------------|----------')

best_ch = -1
best_delta = -999

for ch in range(nc):
    sil_rms = channel_rms(pcm_silence, nc, bps, ch)
    sp_rms = channel_rms(pcm_speech, nc, bps, ch)
    sil_db = rms_to_db(sil_rms)
    sp_db = rms_to_db(sp_rms)
    delta = sp_db - sil_db
    name = ('FL' if ch == 0 else 'FR') if nc <= 2 else f'AUX{ch}'
    marker = ' <--' if delta > 3 else ''
    print(f'  {name:<10}| {sil_db:>12.1f} | {sp_db:>12.1f} | {delta:>8.1f}{marker}')
    if delta > best_delta:
        best_delta = delta
        best_ch = ch

print()
best_name = ('FL' if best_ch == 0 else 'FR') if nc <= 2 else f'AUX{best_ch}'
sp_db = rms_to_db(channel_rms(pcm_speech, nc, bps, best_ch))

if best_delta < 3:
    print('WARNING: No channel showed significant speech activity (delta < 3dB).')
    print('Make sure you spoke during the speech recording phase.')
    print('Falling back to AUX2.')
    best_name = 'AUX2'
else:
    print(f'Recommended channel: {best_name} (speech: {sp_db:.1f} dB, delta: {best_delta:.1f} dB)')
    print()
    print(f'  --pw-channel {best_name}')
    if sp_db < -30:
        print()
        print(f'Note: Signal is quiet ({sp_db:.1f} dB). Check your hardware gain settings.')

print()
print(f'CHANNEL={best_name}')
")

    echo "$result"

    # Cleanup temp files
    rm -f "$silence_file" "$speech_file"
}

# ─── Systemd Service ─────────────────────────────────────────────────────────

install_service() {
    local work_dir="$1"
    local binary="$2"
    local channel="$3"
    local target="${4:-}"

    local service_dir="$HOME/.config/systemd/user"
    mkdir -p "$service_dir"

    local exec_start="$binary --trigger capslock --pw-channel $channel"
    [ -n "$target" ] && exec_start="$exec_start --pw-target $target"

    cat > "$service_dir/zigsper.service" <<EOF
[Unit]
Description=Zigsper push-to-talk dictation

[Service]
Type=simple
WorkingDirectory=$work_dir
ExecStart=$exec_start
Restart=always
RestartSec=5
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable zigsper.service 2>/dev/null || true
    echo "zigsper.service installed."
}

# ─── Subcommands ──────────────────────────────────────────────────────────────

cmd_install() {
    echo "=== Zigsper Installer ==="
    echo ""

    # Verify we're in a dist directory with the binary
    [ -f "$SCRIPT_DIR/zigsper" ] || die "zigsper binary not found in $SCRIPT_DIR"

    # Check runtime deps
    require_cmd nvidia-smi "NVIDIA driver required for CUDA inference."
    command -v pw-cli >/dev/null 2>&1 || echo "WARNING: pw-cli not found. PipeWire may not be installed."

    # Permissions
    check_permissions

    # Download models
    download_models "$SCRIPT_DIR/models"

    # Audio detection
    local channel="FL"
    echo ""
    echo "=== Audio Configuration ==="
    if confirm "Run microphone channel detection? (No = use default FL)"; then
        local detect_output
        detect_output=$(pw_detect)
        echo "$detect_output"
        channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
        [ -z "$channel" ] && channel="FL"
    else
        echo "Using default channel: FL"
    fi

    # Systemd service
    install_service "$SCRIPT_DIR" "$SCRIPT_DIR/zigsper" "$channel"

    echo ""
    if confirm "Start the dictation service now?"; then
        systemctl --user restart zigsper.service
        echo "Service started. Check status with:"
        echo "  systemctl --user status zigsper.service"
    else
        echo ""
        echo "Start manually with:"
        echo "  systemctl --user start zigsper.service"
    fi
}

cmd_setup_dev() {
    # Called from run.ts setup — binary is in the source tree
    local project_dir="${1:?Usage: install.sh setup-dev PROJECT_DIR}"

    check_permissions

    local channel="FL"
    echo ""
    echo "=== Audio Configuration ==="
    if confirm "Run microphone channel detection? (No = use default FL)"; then
        local detect_output
        detect_output=$(pw_detect)
        echo "$detect_output"
        channel=$(echo "$detect_output" | grep '^CHANNEL=' | tail -1 | cut -d= -f2)
        [ -z "$channel" ] && channel="FL"
    else
        echo "Using default channel: FL"
    fi

    install_service "$project_dir" "$project_dir/zig-out/bin/zigsper" "$channel"

    echo ""
    echo "zigsper.service ready"
    if confirm "Start the dictation service now?"; then
        systemctl --user restart zigsper.service
        echo "Service started. Check status with:"
        echo "  systemctl --user status zigsper.service"
    else
        echo ""
        echo "Start manually with:"
        echo "  systemctl --user start zigsper.service"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-install}" in
    install)    cmd_install ;;
    setup-dev)  shift; cmd_setup_dev "$@" ;;
    pw-detect)  shift; pw_detect "$@" ;;
    *)          die "Unknown command: $1. Usage: install.sh [install|pw-detect|setup-dev]" ;;
esac
