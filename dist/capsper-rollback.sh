#!/usr/bin/env bash
set -euo pipefail

# Roll back to the previous capsper version.
# Triggered by OnFailure= when capsper.service crashes repeatedly after an update.
# Only rolls back if the update was applied less than 5 minutes ago.

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"

main() {
    local force=false
    [ "${1:-}" = "--force" ] && force=true

    local prev_file="$INSTALL_DIR/.previous-version"
    local timestamp_file="$INSTALL_DIR/.update-applied-at"

    [ -f "$prev_file" ] || { echo "No previous version to roll back to."; exit 0; }

    # Only auto-rollback if the update was recent (within 5 minutes)
    # Use --force to bypass the time check for manual rollbacks
    if ! $force && [ -f "$timestamp_file" ]; then
        local applied_at now age
        applied_at=$(cat "$timestamp_file")
        if [[ "$applied_at" =~ ^[0-9]+$ ]]; then
            now=$(date +%s)
            age=$((now - applied_at))
            if [ "$age" -ge 300 ]; then
                echo "Update was applied ${age}s ago (>300s). Not rolling back."
                echo "Use --force to roll back anyway."
                exit 0
            fi
        fi
    fi

    local prev
    prev=$(cat "$prev_file")
    [ -d "$INSTALL_DIR/releases/$prev" ] || { echo "Previous release $prev not found." >&2; exit 1; }

    echo "Rolling back to $prev..."

    # Atomic symlink swap back
    ln -sfn "releases/$prev" "$INSTALL_DIR/current.tmp"
    mv -T "$INSTALL_DIR/current.tmp" "$INSTALL_DIR/current"

    # Clean up markers
    rm -f "$prev_file" "$timestamp_file" "$INSTALL_DIR/.update-pending"

    echo "Rolled back to $prev."
    echo "Run: systemctl --user reset-failed capsper.service && systemctl --user start capsper.service"
}

main "$@"
