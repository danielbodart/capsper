#!/usr/bin/env bash
# Shared functions for capsper installers (sourced by linux/install.sh and macos/install.sh).
# Not executable on its own.

# SCRIPT_DIR points to the platform installer's directory (the sourcing script),
# not this file's directory. The sourcing script sets it before sourcing us.
# In a tarball, install-common.sh is alongside install.sh so this works as-is.
# In the repo, the platform installer overrides SCRIPT_DIR before sourcing.
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)}"

HF_ONNX_REPO="danielbodart/nemotron-speech-600m-onnx"
HF_ONNX_BASE="https://huggingface.co/${HF_ONNX_REPO}/resolve/main"
# The int8 export the CPU execution provider runs. Named for the quantisation
# it was produced with; there is one Linux build and so one model to fetch.
ONNX_VARIANT="int8-dynamic"
HF_COREML_REPO="danielbodart/nemotron-speech-600m-coreml"
HF_COREML_BASE="https://huggingface.co/${HF_COREML_REPO}/resolve/main"

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"
RECORDINGS_DIR="$INSTALL_DIR/recordings"  # used by sourcing scripts
export RECORDINGS_DIR

# ─── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    printf '%s [Y/n] ' "$prompt"
    read -r answer
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        ""|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_default_no() {
    local prompt="$1"
    printf '%s [y/N] ' "$prompt"
    read -r answer
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

is_dev_mode() {
    # In the repo: SCRIPT_DIR is dist/linux/ or dist/macos/, so .git is at ../../.git
    # In a tarball: no .git directory exists at all
    [ -d "$SCRIPT_DIR/../.git" ] || [ -d "$SCRIPT_DIR/../../.git" ]
}

# ─── Model Download ──────────────────────────────────────────────────────────

download_models() {
    local model_dir="$1"

    if [ "$(uname -s)" = "Darwin" ]; then
        download_coreml_models "$model_dir"
    else
        download_onnx_models "$model_dir"
    fi
}

download_coreml_models() {
    local model_dir="$1"
    local onnx_dir="$model_dir/nemotron"
    local coreml_dir="$model_dir/nemotron-coreml"
    mkdir -p "$onnx_dir" "$coreml_dir"

    if [ -d "$coreml_dir/encoder.mlmodelc" ] && [ -d "$coreml_dir/decoder.mlmodelc" ] \
       && [ -f "$onnx_dir/filterbank.bin" ] && [ -f "$onnx_dir/tokens.txt" ]; then
        echo "CoreML models already present."
        return
    fi

    echo "Detected hardware: Apple Silicon (CoreML)"
    echo "Model: Nemotron Speech 600M CoreML (FP16, 93% ANE)"

    if ! confirm "Download now?"; then
        echo ""
        echo "Models directory: $coreml_dir"
        echo "Download manually from: https://huggingface.co/$HF_COREML_REPO"
        return
    fi

    require_cmd curl "Install curl to download models."
    echo "Downloading CoreML models..."

    for model in encoder decoder; do
        local mlmodelc_dir="$coreml_dir/${model}.mlmodelc"
        mkdir -p "$mlmodelc_dir/weights" "$mlmodelc_dir/analytics"
        curl -L --progress-bar -o "$mlmodelc_dir/model.mil" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/model.mil"
        curl -L --progress-bar -o "$mlmodelc_dir/coremldata.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/coremldata.bin"
        curl -L --progress-bar -o "$mlmodelc_dir/metadata.json" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/metadata.json"
        curl -L --progress-bar -o "$mlmodelc_dir/weights/weight.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/weights/weight.bin"
        curl -L --progress-bar -o "$mlmodelc_dir/analytics/coremldata.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/analytics/coremldata.bin"
    done

    curl -L --progress-bar -o "$onnx_dir/filterbank.bin" \
        "$HF_ONNX_BASE/shared/filterbank.bin"
    curl -L --progress-bar -o "$onnx_dir/tokens.txt" \
        "$HF_ONNX_BASE/shared/tokens.txt"

    echo "CoreML models downloaded."
}

download_onnx_models() {
    local model_dir="$1"
    local target_dir="$model_dir/nemotron"
    mkdir -p "$target_dir"

    if [ -f "$target_dir/encoder_model.onnx" ] && [ -f "$target_dir/decoder_model.onnx" ] \
       && [ -f "$target_dir/filterbank.bin" ] && [ -f "$target_dir/tokens.txt" ]; then
        echo "ONNX models already present."
        return
    fi

    echo "Model: Nemotron Speech 600M ONNX (int8)"

    if ! confirm "Download now?"; then
        echo ""
        echo "Models directory: $target_dir"
        echo "Download manually from: https://huggingface.co/$HF_ONNX_REPO"
        return
    fi

    require_cmd curl "Install curl to download models."
    echo "Downloading ONNX model..."

    curl -L --progress-bar -o "$target_dir/encoder_model.onnx" \
        "$HF_ONNX_BASE/$ONNX_VARIANT/encoder_model.onnx"
    curl -L --progress-bar -o "$target_dir/encoder_model.onnx.data" \
        "$HF_ONNX_BASE/$ONNX_VARIANT/encoder_model.onnx.data"
    curl -L --progress-bar -o "$target_dir/decoder_model.onnx" \
        "$HF_ONNX_BASE/$ONNX_VARIANT/decoder_model.onnx"
    curl -L --progress-bar -o "$target_dir/decoder_model.onnx.data" \
        "$HF_ONNX_BASE/$ONNX_VARIANT/decoder_model.onnx.data"
    curl -L --progress-bar -o "$target_dir/filterbank.bin" \
        "$HF_ONNX_BASE/shared/filterbank.bin"
    curl -L --progress-bar -o "$target_dir/tokens.txt" \
        "$HF_ONNX_BASE/shared/tokens.txt"
    curl -L --progress-bar -o "$target_dir/config.json" \
        "$HF_ONNX_BASE/config.json"

    echo "ONNX model downloaded."
}

# ─── Install Files ────────────────────────────────────────────────────────────

install_files() {
    echo "Installing to $INSTALL_DIR ..."

    [ -d "$SCRIPT_DIR/bin" ] || die "bin/ not found in dist."
    [ -f "$SCRIPT_DIR/VERSION" ] || die "VERSION file not found in dist."

    local ver
    ver=$(cat "$SCRIPT_DIR/VERSION")
    local release_dir="$INSTALL_DIR/releases/v$ver"

    mkdir -p "$release_dir"

    cp -a "$SCRIPT_DIR/bin" "$release_dir/"
    cp "$SCRIPT_DIR/VERSION" "$release_dir/"
    mkdir -p "$release_dir/models"

    # Models small enough to ship in the tarball (the voice activity model).
    # The big ASR model is downloaded separately by download_models.
    if [ -d "$SCRIPT_DIR/models" ]; then
        cp -a "$SCRIPT_DIR/models/." "$release_dir/models/"
    fi

    # The ONNX Runtime libraries ship in the tarball. They live in one shared
    # directory rather than once per release: every release so far has used the
    # same build, and each copy is 24MB.
    local shared_lib="$INSTALL_DIR/lib"
    if [ -f "$SCRIPT_DIR/lib/libonnxruntime.so" ]; then
        mkdir -p "$shared_lib"
        cp -a "$SCRIPT_DIR/lib/"* "$shared_lib/"
    fi
    if [ -f "$shared_lib/libonnxruntime.so" ]; then
        ln -sfn "$shared_lib" "$release_dir/lib"
    fi

    # Save current version for rollback (if upgrading)
    local current_target
    current_target=$(readlink "$INSTALL_DIR/current" 2>/dev/null || true)
    if [ -n "$current_target" ]; then
        local current_name
        current_name=$(basename "$current_target")
        if [ "$current_name" != "v$ver" ]; then
            echo "$current_name" > "$INSTALL_DIR/.previous-version"
            date +%s > "$INSTALL_DIR/.update-applied-at"
        fi
    fi

    # Atomic symlink swap
    ln -sfn "releases/v$ver" "$INSTALL_DIR/current.tmp"
    rm -f "$INSTALL_DIR/current"
    mv "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Install scripts (capsper-update.sh is always present; others are platform-specific).
    # In a tarball, all scripts are in SCRIPT_DIR. In the repo, install-common.sh
    # is in the sibling shared/ directory.
    for script in capsper-update.sh capsper-apply-update.sh capsper-rollback.sh install-common.sh; do
        if [ -f "$SCRIPT_DIR/$script" ]; then
            cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$script"
        elif [ -f "$SCRIPT_DIR/../shared/$script" ]; then
            cp "$SCRIPT_DIR/../shared/$script" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$script"
        fi
    done

    # Clean up old flat layout (migration from pre-versioned installs)
    # Only remove $INSTALL_DIR/bin — $INSTALL_DIR/lib is now the shared ORT lib location
    if [ -d "$INSTALL_DIR/bin" ] && [ ! -L "$INSTALL_DIR/bin" ]; then
        rm -rf "${INSTALL_DIR:?}/bin"
        echo "Migrated from flat layout to versioned directories."
    fi

    # Clean up old releases (keep current + previous)
    local prev
    prev=$(cat "$INSTALL_DIR/.previous-version" 2>/dev/null || true)
    for dir in "$INSTALL_DIR/releases"/v*; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        [ "$name" = "v$ver" ] && continue
        [ "$name" = "$prev" ] && continue
        echo "Removing old release: $name"
        rm -rf "$dir"
    done

    # Symlink into ~/.local/bin so capsper and capsper-update are on PATH
    mkdir -p "$HOME/.local/bin"
    ln -sf "$INSTALL_DIR/current/bin/capsper" "$HOME/.local/bin/capsper"
    ln -sf "$INSTALL_DIR/capsper-update.sh" "$HOME/.local/bin/capsper-update"

    echo "Installed v$ver. Binary: $INSTALL_DIR/current/bin/capsper"
    echo "Commands: ~/.local/bin/capsper, ~/.local/bin/capsper-update"

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
        echo ""
        echo "NOTE: ~/.local/bin is not on your PATH."
        echo "Add to your shell rc file:"
        # shellcheck disable=SC2016
        echo '  export PATH="$HOME/.local/bin:$PATH"'
    fi
}

# ─── Dry-Run Validation ──────────────────────────────────────────────────────

run_dry_run() {
    local binary="$1"
    shift
    local args=("$@")

    echo ""
    echo "=== Validating Setup ==="
    echo ""

    local exit_code=0
    "$binary" "${args[@]}" --dry-run 2>&1 || exit_code=$?

    echo ""

    if [ $exit_code -ne 0 ]; then
        echo "Setup validation failed. Fix the issues above before starting the service."
        return 1
    fi

    echo "Setup validated successfully."
}
