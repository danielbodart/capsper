#!/usr/bin/env bash
set -euo pipefail

# Check for capsper updates from GitHub Releases.
# Called by capsper-update.timer (daily).
# Downloads and stages new versions; does NOT apply them.
# The update is applied on next service restart via capsper-apply-update.sh.

REPO="danielbodart/capsper"
ASSET="capsper-linux-x86_64.tar.gz"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"
TMP_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

current_version() {
    cat "$INSTALL_DIR/current/VERSION" 2>/dev/null || echo "unknown"
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
        (cd "$TMP_DIR" && sha256sum -c "$ASSET.sha256") || die "SHA256 verification failed"
        echo "SHA256 verified."
    fi

    # Stage: extract to releases/vX.Y.Z/
    local release_dir="$INSTALL_DIR/releases/$latest_tag"
    rm -rf "$release_dir"
    mkdir -p "$release_dir"
    tar -xzf "$TMP_DIR/$ASSET" -C "$release_dir"

    # Validate critical files exist
    [ -f "$release_dir/bin/capsper" ] || die "Extracted release is missing capsper binary"
    [ -d "$release_dir/lib" ] || die "Extracted release is missing lib/ directory"

    # Update top-level scripts from staged release
    for script in capsper-update.sh capsper-apply-update.sh capsper-rollback.sh; do
        if [ -f "$release_dir/$script" ]; then
            cp "$release_dir/$script" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/$script"
        fi
    done

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
