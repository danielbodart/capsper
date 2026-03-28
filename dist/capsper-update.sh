#!/usr/bin/env bash
set -euo pipefail

# Check for capsper updates from GitHub Releases.
# Called by capsper-update.timer (daily).
# Downloads and stages new versions; does NOT apply them.
# The update is applied on next service restart via capsper-apply-update.sh.

REPO="danielbodart/capsper"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"
HF_ONNX_REPO="danielbodart/nemotron-speech-600m-onnx"
HF_ONNX_BASE="https://huggingface.co/${HF_ONNX_REPO}/resolve/main"
HF_COREML_REPO="danielbodart/nemotron-speech-600m-coreml"
HF_COREML_BASE="https://huggingface.co/${HF_COREML_REPO}/resolve/main"
TMP_DIR=""

IS_MACOS=false
if [ "$(uname -s)" = "Darwin" ]; then
    IS_MACOS=true
    ASSET="capsper-macos-arm64.tar.gz"
else
    ASSET="capsper-linux-x86_64.tar.gz"
    DEPS_ASSET="capsper-linux-x86_64-deps.tar.gz"
fi

sha256_check() {
    if $IS_MACOS; then
        shasum -a 256 -c "$1"
    else
        sha256sum -c "$1"
    fi
}

die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

current_version() {
    cat "$INSTALL_DIR/current/VERSION" 2>/dev/null || echo "unknown"
}

detect_model_variant() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        echo "int8-static"
    else
        echo "int8-dynamic"
    fi
}

ensure_models() {
    if $IS_MACOS; then
        ensure_coreml_models
    else
        ensure_nemotron_model
    fi
}

ensure_coreml_models() {
    local coreml_dir="$INSTALL_DIR/models/nemotron-coreml"
    local onnx_dir="$INSTALL_DIR/models/nemotron"
    if [ -d "$coreml_dir/encoder.mlmodelc" ] && [ -d "$coreml_dir/decoder.mlmodelc" ] \
       && [ -f "$onnx_dir/filterbank.bin" ] && [ -f "$onnx_dir/tokens.txt" ]; then
        return 0
    fi
    download_coreml_models
}

download_coreml_models() {
    local coreml_dir="$INSTALL_DIR/models/nemotron-coreml"
    local onnx_dir="$INSTALL_DIR/models/nemotron"
    mkdir -p "$coreml_dir" "$onnx_dir"

    echo "Downloading CoreML models..."
    for model in encoder decoder; do
        local mlmodelc_dir="$coreml_dir/${model}.mlmodelc"
        mkdir -p "$mlmodelc_dir/analytics"
        curl -fsSL -o "$mlmodelc_dir/model.mlmodel" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/model.mlmodel"
        curl -fsSL -o "$mlmodelc_dir/coremldata.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/coremldata.bin"
        curl -fsSL -o "$mlmodelc_dir/analytics/coremldata.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/analytics/coremldata.bin"
    done

    # Shared files (filterbank + tokenizer)
    curl -fsSL -o "$onnx_dir/filterbank.bin" "$HF_ONNX_BASE/shared/filterbank.bin"
    curl -fsSL -o "$onnx_dir/tokens.txt" "$HF_ONNX_BASE/shared/tokens.txt"
    echo "CoreML models downloaded."
}

ensure_nemotron_model() {
    local model_dir="$INSTALL_DIR/models/nemotron"
    if [ ! -f "$model_dir/encoder_model.onnx" ] || [ ! -f "$model_dir/decoder_model.onnx" ] \
       || [ ! -f "$model_dir/filterbank.bin" ] || [ ! -f "$model_dir/tokens.txt" ]; then
        download_nemotron_model "$model_dir"
    fi
}

download_nemotron_model() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local variant
    variant=$(detect_model_variant)
    echo "Downloading Nemotron model ($variant)..."

    curl -fsSL -o "$target_dir/encoder_model.onnx" "$HF_ONNX_BASE/$variant/encoder_model.onnx" || return 1
    curl -fsSL -o "$target_dir/encoder_model.onnx.data" "$HF_ONNX_BASE/$variant/encoder_model.onnx.data" || return 1
    curl -fsSL -o "$target_dir/decoder_model.onnx" "$HF_ONNX_BASE/$variant/decoder_model.onnx" || return 1
    curl -fsSL -o "$target_dir/decoder_model.onnx.data" "$HF_ONNX_BASE/$variant/decoder_model.onnx.data" || return 1
    curl -fsSL -o "$target_dir/filterbank.bin" "$HF_ONNX_BASE/shared/filterbank.bin" || return 1
    curl -fsSL -o "$target_dir/tokens.txt" "$HF_ONNX_BASE/shared/tokens.txt" || return 1
    curl -fsSL -o "$target_dir/config.json" "$HF_ONNX_BASE/config.json" || return 1

    echo "Nemotron model downloaded ($variant)."
}

ensure_ort_libs() {
    local release_dir="$1"
    local release_tag="$2"
    local shared_lib="$INSTALL_DIR/lib"
    local needed_version=""

    # Read required deps version from staged release
    if [ -f "$release_dir/lib/DEPS_VERSION" ]; then
        needed_version=$(cat "$release_dir/lib/DEPS_VERSION")
    fi

    # If the release has real .so files (old-style tarball), move them to shared
    if [ -f "$release_dir/lib/libonnxruntime.so" ]; then
        echo "Migrating bundled ORT libs to shared directory..."
        mkdir -p "$shared_lib"
        cp -a "$release_dir/lib/"*.so "$release_dir/lib/"*.so.* "$shared_lib/" 2>/dev/null || true
        [ -n "$needed_version" ] && cp "$release_dir/lib/DEPS_VERSION" "$shared_lib/"
        return 0
    fi

    # Check if shared libs already match the needed version
    if [ -n "$needed_version" ] && [ -f "$shared_lib/DEPS_VERSION" ]; then
        local current_version
        current_version=$(cat "$shared_lib/DEPS_VERSION")
        if [ "$current_version" = "$needed_version" ]; then
            return 0
        fi
    fi

    # Shared libs exist but no version tracking yet (transition from old-style).
    # Accept them — the next ORT upgrade will set DEPS_VERSION properly.
    if [ -f "$shared_lib/libonnxruntime.so" ] && [ ! -f "$shared_lib/DEPS_VERSION" ]; then
        return 0
    fi

    # Download deps tarball from the same GitHub release
    echo "Downloading ORT runtime libraries..."
    local deps_url="https://github.com/$REPO/releases/download/$release_tag/$DEPS_ASSET"
    curl -fSL -o "$TMP_DIR/$DEPS_ASSET" "$deps_url" || {
        echo "WARNING: Failed to download deps tarball from $deps_url"
        echo "ORT libs may need to be installed manually."
        return 1
    }

    # Verify SHA256 if available
    if curl -fSL -o "$TMP_DIR/$DEPS_ASSET.sha256" \
        "https://github.com/$REPO/releases/download/$release_tag/$DEPS_ASSET.sha256" 2>/dev/null; then
        (cd "$TMP_DIR" && sha256_check "$DEPS_ASSET.sha256") || die "Deps SHA256 verification failed"
        echo "Deps SHA256 verified."
    fi

    mkdir -p "$shared_lib" "$TMP_DIR/deps"
    tar -xzf "$TMP_DIR/$DEPS_ASSET" -C "$TMP_DIR/deps"
    cp -a "$TMP_DIR/deps/lib/"* "$shared_lib/"
    echo "ORT runtime libraries installed."
}

main() {
    local current
    current=$(current_version)
    echo "Current version: $current"

    # Fetch latest release tag from GitHub API
    local release_json
    release_json=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") \
        || die "Failed to fetch release info from GitHub"

    local latest_tag
    latest_tag=$(echo "$release_json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
    [ -n "$latest_tag" ] || die "Could not parse latest release tag"

    local latest_ver="${latest_tag#v}"
    echo "Latest version: $latest_ver"

    if [ "$current" = "$latest_ver" ]; then
        echo "Already up to date."
        exit 0
    fi

    # Check if already staged
    if [ -f "$INSTALL_DIR/.update-pending" ]; then
        local pending
        pending=$(cat "$INSTALL_DIR/.update-pending")
        if [ "$pending" = "$latest_tag" ]; then
            # Ensure model is downloaded even if a previous run staged the
            # release but was missing the download logic (whisper → nemotron transition)
            ensure_nemotron_model
            echo "Update $latest_tag already staged, pending restart."
            exit 0
        fi
    fi

    echo "Downloading $latest_tag..."

    TMP_DIR=$(mktemp -d)

    curl -fSL -o "$TMP_DIR/$ASSET" \
        "https://github.com/$REPO/releases/download/$latest_tag/$ASSET"

    # Verify SHA256 checksum
    if curl -fSL -o "$TMP_DIR/$ASSET.sha256" \
        "https://github.com/$REPO/releases/download/$latest_tag/$ASSET.sha256" 2>/dev/null; then
        (cd "$TMP_DIR" && sha256_check "$ASSET.sha256") || die "SHA256 verification failed"
        echo "SHA256 verified."
    fi

    # Stage: extract to releases/vX.Y.Z/
    local release_dir="$INSTALL_DIR/releases/$latest_tag"
    rm -rf "$release_dir"
    mkdir -p "$release_dir"
    tar -xzf "$TMP_DIR/$ASSET" -C "$release_dir"

    # Validate critical files exist
    if $IS_MACOS; then
        [ -f "$release_dir/bin/capsper" ] || die "Extracted release is missing capsper binary"
    else
        [ -f "$release_dir/bin/capsper-cuda" ] || [ -f "$release_dir/bin/capsper-cpu" ] \
            || [ -f "$release_dir/bin/capsper" ] \
            || die "Extracted release is missing capsper binaries"
    fi

    # Update top-level scripts from staged release
    for script in capsper-update.sh capsper-apply-update.sh capsper-rollback.sh; do
        if [ -f "$release_dir/$script" ]; then
            cp "$release_dir/$script" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$script"
        fi
    done

    # Platform-specific post-extraction
    if $IS_MACOS; then
        # Remove quarantine so Gatekeeper doesn't block the signed binary
        xattr -d com.apple.quarantine "$release_dir/bin/capsper" 2>/dev/null || true
    else
        # Ensure ORT shared libs are present (downloads deps tarball if needed)
        ensure_ort_libs "$release_dir" "$latest_tag"
    fi

    # Download models if not present or incomplete
    ensure_models

    # Clean up old releases (keep current + previous + newly staged)
    local keep_current keep_previous
    keep_current=$(readlink "$INSTALL_DIR/current" 2>/dev/null | xargs basename 2>/dev/null || true)
    keep_previous=$(cat "$INSTALL_DIR/.previous-version" 2>/dev/null || true)
    for dir in "$INSTALL_DIR/releases"/v*; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        [ "$name" = "$keep_current" ] && continue
        [ "$name" = "$keep_previous" ] && continue
        [ "$name" = "$latest_tag" ] && continue
        echo "Removing old release: $name"
        rm -rf "$dir"
    done

    # Mark update as pending
    echo "$latest_tag" > "$INSTALL_DIR/.update-pending"

    echo "Update $latest_tag staged. Will be applied on next service restart."
}

main "$@"
