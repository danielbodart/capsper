#!/usr/bin/env bash
set -euo pipefail

# Apply a staged capsper update (atomic symlink swap).
# Called as ExecStartPre= before capsper starts.
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

    # Atomic symlink swap: ln creates new symlink, mv atomically replaces via rename(2)
    ln -sfn "releases/$pending" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    rm -f "$pending_file"

    echo "Applied update: $pending"
}

main "$@"
