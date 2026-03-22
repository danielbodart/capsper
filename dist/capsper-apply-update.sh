#!/usr/bin/env bash
set -euo pipefail

# Apply a staged capsper update (atomic symlink swap + service migration).
# Called as ExecStartPre= before capsper starts.
# Only acts if .update-pending exists.

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"
HF_REPO="danielbodart/nemotron-speech-600m-onnx"
HF_BASE="https://huggingface.co/${HF_REPO}/resolve/main"

main() {
    local pending_file="$INSTALL_DIR/.update-pending"

    [ -f "$pending_file" ] || exit 0

    local pending
    pending=$(cat "$pending_file")
    [ -n "$pending" ] || exit 0

    local release_dir="$INSTALL_DIR/releases/$pending"
    [ -d "$release_dir/bin" ] || { echo "ERROR: Staged release $pending not found" >&2; exit 1; }

    # Save current version for rollback
    local current_target
    current_target=$(readlink "$INSTALL_DIR/current" 2>/dev/null || true)
    if [ -n "$current_target" ]; then
        basename "$current_target" > "$INSTALL_DIR/.previous-version"
        date +%s > "$INSTALL_DIR/.update-applied-at"
    fi

    # Clear debug recordings on version change
    local recordings_dir="$INSTALL_DIR/recordings"
    if [ -d "$recordings_dir" ]; then
        echo "Clearing debug recordings (version change)..."
        rm -f "$recordings_dir"/*.wav "$recordings_dir"/*.log 2>/dev/null || true
    fi

    # Symlink shared models into the new release so the binary can find them
    # via its default relative path (bin/../models/).
    local shared_models_dir="$INSTALL_DIR/models"
    local release_models_dir="$release_dir/models"
    if [ -d "$shared_models_dir" ]; then
        mkdir -p "$release_models_dir"
        for model in "$shared_models_dir"/*; do
            [ -e "$model" ] || continue
            local name
            name=$(basename "$model")
            [ -e "$release_models_dir/$name" ] && continue
            ln -sf "$model" "$release_models_dir/$name"
        done
    fi

    # Download Nemotron model if not present (first update from whisper → nemotron)
    if [ ! -d "$shared_models_dir/nemotron" ] || [ ! -f "$shared_models_dir/nemotron/encoder_model.onnx" ]; then
        echo "Downloading Nemotron model (first-time migration from whisper)..."
        download_nemotron_model "$shared_models_dir"
        # Symlink into release
        if [ -d "$shared_models_dir/nemotron" ]; then
            ln -sf "$shared_models_dir/nemotron" "$release_models_dir/nemotron" 2>/dev/null || true
        fi
    fi

    # Migrate systemd service file: update model path, strip removed flags
    migrate_service_config

    # Atomic symlink swap: ln creates new symlink, mv atomically replaces via rename(2)
    ln -sfn "releases/$pending" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    rm -f "$pending_file"

    echo "Applied update: $pending"
}

detect_model_variant() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        echo "fp16"
    elif [ "$(uname -m)" = "arm64" ] && [ "$(uname -s)" = "Darwin" ]; then
        echo "fp16"
    else
        echo "int8"
    fi
}

download_nemotron_model() {
    local models_dir="$1"
    local target_dir="$models_dir/nemotron"
    mkdir -p "$target_dir"

    local variant
    variant=$(detect_model_variant)
    echo "Detected hardware → $variant precision"

    if ! command -v curl &>/dev/null; then
        echo "WARNING: curl not found, cannot download model" >&2
        return 1
    fi

    curl -fsSL -o "$target_dir/encoder_model.onnx" "$HF_BASE/$variant/encoder_model.onnx" || return 1
    curl -fsSL -o "$target_dir/encoder_model.onnx.data" "$HF_BASE/$variant/encoder_model.onnx.data" || return 1
    curl -fsSL -o "$target_dir/decoder_model.onnx" "$HF_BASE/$variant/decoder_model.onnx" || return 1
    curl -fsSL -o "$target_dir/decoder_model.onnx.data" "$HF_BASE/$variant/decoder_model.onnx.data" || return 1
    curl -fsSL -o "$target_dir/filterbank.bin" "$HF_BASE/shared/filterbank.bin" || return 1
    curl -fsSL -o "$target_dir/tokens.txt" "$HF_BASE/shared/tokens.txt" || return 1
    curl -fsSL -o "$target_dir/config.json" "$HF_BASE/config.json" || return 1

    echo "Nemotron model downloaded ($variant)."
}

migrate_service_config() {
    local service_file="$HOME/.config/systemd/user/capsper.service"
    [ -f "$service_file" ] || return 0

    local exec_start
    exec_start=$(grep '^ExecStart=' "$service_file" | sed 's/^ExecStart=//')
    [ -n "$exec_start" ] || return 0

    # Nothing to migrate if already using nemotron model path
    echo "$exec_start" | grep -q '/nemotron' && return 0

    echo "Migrating service config to Nemotron..."

    local new_exec_start="$exec_start"

    # Replace old whisper model path with nemotron
    new_exec_start=$(echo "$new_exec_start" | sed 's|--model [^ ]*|--model '"$INSTALL_DIR"'/models/nemotron|')

    # Strip removed flags (with their arguments)
    new_exec_start=$(echo "$new_exec_start" | sed 's/--domain-terms [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--warmup-file [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--asr [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--vad [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--vad-threshold [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--vad-threshold-off [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--min-silence-ms [^ ]* *//g')
    new_exec_start=$(echo "$new_exec_start" | sed 's/--max-tokens-per-sec [^ ]* *//g')

    # Strip flags without arguments
    new_exec_start=$(echo "$new_exec_start" | sed 's/--no-warmup *//g')

    # Clean up double spaces
    new_exec_start=$(echo "$new_exec_start" | sed 's/  */ /g; s/ *$//')

    if [ "$new_exec_start" != "$exec_start" ]; then
        # Escape sed delimiter in paths
        local escaped_old escaped_new
        escaped_old=$(printf '%s\n' "$exec_start" | sed 's/[&/\]/\\&/g')
        escaped_new=$(printf '%s\n' "$new_exec_start" | sed 's/[&/\]/\\&/g')
        sed -i "s|^ExecStart=.*|ExecStart=$new_exec_start|" "$service_file"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "Service config migrated."
        echo "  Old: $exec_start"
        echo "  New: $new_exec_start"
    fi
}

main "$@"
