#!/usr/bin/env bash
set -euo pipefail

# Manual update script for capsper (macOS).
# Downloads the latest release, stages it, and immediately applies.
# Usage: capsper-update

REPO="danielbodart/capsper"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"
HF_ONNX_REPO="danielbodart/nemotron-speech-600m-onnx"
HF_ONNX_BASE="https://huggingface.co/${HF_ONNX_REPO}/resolve/main"
HF_COREML_REPO="danielbodart/nemotron-speech-600m-coreml"
HF_COREML_BASE="https://huggingface.co/${HF_COREML_REPO}/resolve/main"
ASSET="capsper-macos-arm64.tar.gz"
TMP_DIR=""

PLIST_LABEL="io.github.danielbodart.capsper"

die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

current_version() {
    cat "$INSTALL_DIR/current/VERSION" 2>/dev/null || echo "unknown"
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
        mkdir -p "$mlmodelc_dir/weights" "$mlmodelc_dir/analytics"
        curl -fsSL -o "$mlmodelc_dir/model.mil" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/model.mil"
        curl -fsSL -o "$mlmodelc_dir/coremldata.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/coremldata.bin"
        curl -fsSL -o "$mlmodelc_dir/metadata.json" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/metadata.json"
        curl -fsSL -o "$mlmodelc_dir/weights/weight.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/weights/weight.bin"
        curl -fsSL -o "$mlmodelc_dir/analytics/coremldata.bin" \
            "$HF_COREML_BASE/fp16/${model}.mlmodelc/analytics/coremldata.bin"
    done

    # Shared files (filterbank + tokenizer)
    curl -fsSL -o "$onnx_dir/filterbank.bin" "$HF_ONNX_BASE/shared/filterbank.bin"
    curl -fsSL -o "$onnx_dir/tokens.txt" "$HF_ONNX_BASE/shared/tokens.txt"
    echo "CoreML models downloaded."
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

    echo "Downloading $latest_tag..."

    TMP_DIR=$(mktemp -d)

    curl -fSL -o "$TMP_DIR/$ASSET" \
        "https://github.com/$REPO/releases/download/$latest_tag/$ASSET"

    # Verify SHA256 checksum
    if curl -fSL -o "$TMP_DIR/$ASSET.sha256" \
        "https://github.com/$REPO/releases/download/$latest_tag/$ASSET.sha256" 2>/dev/null; then
        (cd "$TMP_DIR" && shasum -a 256 -c "$ASSET.sha256") || die "SHA256 verification failed"
        echo "SHA256 verified."
    fi

    # Stage: extract to releases/vX.Y.Z/
    local release_dir="$INSTALL_DIR/releases/$latest_tag"
    rm -rf "$release_dir"
    mkdir -p "$release_dir"
    tar -xzf "$TMP_DIR/$ASSET" -C "$release_dir"

    # Validate critical files exist
    [ -f "$release_dir/bin/capsper" ] || die "Extracted release is missing capsper binary"

    # Update the update script itself from the new release
    if [ -f "$release_dir/capsper-update.sh" ]; then
        cp "$release_dir/capsper-update.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/capsper-update.sh"
    fi

    # Remove quarantine so Gatekeeper doesn't block the signed binary
    xattr -d com.apple.quarantine "$release_dir/bin/capsper" 2>/dev/null || true

    # Download models if not present or incomplete
    ensure_coreml_models

    # Symlink shared models into the new release
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

    # Stop the service before swapping
    local was_running=false
    if launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
        was_running=true
        echo "Stopping service..."
        launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    fi

    # Atomic symlink swap
    ln -sfn "releases/$latest_tag" "$INSTALL_DIR/current.tmp"
    rm -f "$INSTALL_DIR/current"
    mv "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Copy binary to stable path (TCC tracks by absolute path).
    # Reset mic permission — TCC stores the cdhash at grant time, so a new
    # binary at the same path gets silently denied. Resetting clears the stale
    # entry so the next launch triggers a fresh mic permission dialog.
    mkdir -p "$INSTALL_DIR/bin"
    tccutil reset Microphone 2>/dev/null || true
    cp "$release_dir/bin/capsper" "$INSTALL_DIR/bin/capsper.tmp"
    mv "$INSTALL_DIR/bin/capsper.tmp" "$INSTALL_DIR/bin/capsper"

    # Clean up old releases (keep only current)
    local keep_current
    keep_current=$(basename "$(readlink "$INSTALL_DIR/current")")
    for dir in "$INSTALL_DIR/releases"/v*; do
        [ -d "$dir" ] || continue
        local name
        name=$(basename "$dir")
        [ "$name" = "$keep_current" ] && continue
        echo "Removing old release: $name"
        rm -rf "$dir"
    done

    echo "Updated to $latest_tag."

    # Restart service if it was running
    if $was_running; then
        local plist_path="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
        if [ -f "$plist_path" ]; then
            echo "Restarting service..."
            launchctl bootstrap "gui/$(id -u)" "$plist_path"
            echo "Service restarted. Check logs with:"
            echo "  tail -f $INSTALL_DIR/capsper.log"
        fi
    fi
}

main "$@"
