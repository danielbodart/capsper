#!/usr/bin/env bash
set -euo pipefail

# Apply a staged capsper update (atomic symlink swap + service migration).
# Called as ExecStartPre= before capsper starts (Linux only).
# Only acts if .update-pending exists.

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"

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

    # Symlink shared ORT libs into the new release so the binary can find
    # them via RPATH ($ORIGIN/../lib).
    local shared_lib_dir="$INSTALL_DIR/lib"
    local release_lib_dir="$release_dir/lib"
    if [ -d "$release_lib_dir" ] && [ -f "$release_lib_dir/libonnxruntime.so" ]; then
        mkdir -p "$shared_lib_dir"
        cp -a "$release_lib_dir/"*.so "$release_lib_dir/"*.so.* "$shared_lib_dir/" 2>/dev/null || true
        [ -f "$release_lib_dir/DEPS_VERSION" ] && cp "$release_lib_dir/DEPS_VERSION" "$shared_lib_dir/"
    fi
    if [ ! -f "$shared_lib_dir/libonnxruntime.so" ] && [ -n "$current_target" ]; then
        local prev_lib="$INSTALL_DIR/$current_target/lib"
        if [ -d "$prev_lib" ] && [ -f "$prev_lib/libonnxruntime.so" ]; then
            echo "Migrating ORT libs from previous release to shared directory..."
            mkdir -p "$shared_lib_dir"
            cp -a "$prev_lib/"*.so "$prev_lib/"*.so.* "$shared_lib_dir/" 2>/dev/null || true
            [ -f "$prev_lib/DEPS_VERSION" ] && cp "$prev_lib/DEPS_VERSION" "$shared_lib_dir/"
        fi
    fi
    if [ -d "$shared_lib_dir" ] && [ -f "$shared_lib_dir/libonnxruntime.so" ]; then
        rm -rf "$release_lib_dir"
        ln -sfn "$shared_lib_dir" "$release_lib_dir"
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

    # Abort if models are missing — the update script should have downloaded them.
    local nemotron_dir="$INSTALL_DIR/models/nemotron"
    if [ ! -f "$nemotron_dir/encoder_model.onnx" ] || [ ! -f "$nemotron_dir/decoder_model.onnx" ] \
       || [ ! -f "$nemotron_dir/filterbank.bin" ] || [ ! -f "$nemotron_dir/tokens.txt" ]; then
        echo "ERROR: Nemotron model not found in $nemotron_dir" >&2
        echo "Run: ~/.local/share/capsper/capsper-update.sh" >&2
        exit 1
    fi

    # Migrate systemd service file: update model path, strip removed flags
    migrate_service_config

    # Create bin/capsper symlink to the right variant for this machine.
    local target="capsper-cpu"
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        target="capsper-cuda"
    fi
    ln -sf "$target" "$release_dir/bin/capsper"
    echo "Selected binary: $target"

    # Atomic symlink swap (for models, scripts, VERSION, etc.)
    ln -sfn "releases/$pending" "$INSTALL_DIR/current.tmp"
    rm -f "$INSTALL_DIR/current"
    mv "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Copy the selected variant to a stable path for service configs.
    # Uses cp + mv for atomic replacement (mv is atomic on same filesystem).
    mkdir -p "$INSTALL_DIR/bin"
    local selected
    selected=$(readlink "$release_dir/bin/capsper" 2>/dev/null || echo "capsper")
    cp "$release_dir/bin/$selected" "$INSTALL_DIR/bin/capsper.tmp"
    mv "$INSTALL_DIR/bin/capsper.tmp" "$INSTALL_DIR/bin/capsper"

    rm -f "$pending_file"

    echo "Applied update: $pending"
}

migrate_service_config() {
    local service_file="$HOME/.config/systemd/user/capsper.service"
    [ -f "$service_file" ] || return 0

    local exec_start
    exec_start=$(grep '^ExecStart=' "$service_file" | sed 's/^ExecStart=//')
    [ -n "$exec_start" ] || return 0

    local new_exec_start="$exec_start"
    local needs_migrate=false

    # Migrate old whisper model path to nemotron
    if ! echo "$exec_start" | grep -q '/nemotron'; then
        echo "Migrating service config to Nemotron..."
        needs_migrate=true

        # Replace old whisper model path with nemotron
        # shellcheck disable=SC2001
        new_exec_start=$(sed 's|--model [^ ]*|--model '"$INSTALL_DIR"'/models/nemotron|' <<< "$new_exec_start")

        # Strip removed flags (with their arguments)
        local flag
        for flag in --domain-terms --warmup-file --asr --vad --vad-threshold --vad-threshold-off --min-silence-ms --max-tokens-per-sec --input; do
            new_exec_start="${new_exec_start//$flag [^ ]* /}"
            new_exec_start="${new_exec_start//$flag [^ ]*/}"
        done

        # Strip flags without arguments
        new_exec_start="${new_exec_start//--no-warmup /}"
        new_exec_start="${new_exec_start//--no-warmup/}"
    fi

    # Migrate --pw-* flags to --audio-* (cross-platform rename)
    if echo "$new_exec_start" | grep -q -- '--pw-'; then
        needs_migrate=true
        new_exec_start="${new_exec_start//--pw-channel /--audio-channel }"
        new_exec_start="${new_exec_start//--pw-target /--audio-target }"
        new_exec_start="${new_exec_start//--pw-gain /--audio-gain }"
        new_exec_start="${new_exec_start//--pw-detect/--audio-detect}"
    fi

    $needs_migrate || return 0

    # Clean up double spaces and trailing space
    while [[ "$new_exec_start" == *"  "* ]]; do
        new_exec_start="${new_exec_start//  / }"
    done
    new_exec_start="${new_exec_start% }"

    if [ "$new_exec_start" != "$exec_start" ]; then
        sed -i "s|^ExecStart=.*|ExecStart=$new_exec_start|" "$service_file"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "Service config migrated."
        echo "  Old: $exec_start"
        echo "  New: $new_exec_start"
    fi
}

main "$@"
