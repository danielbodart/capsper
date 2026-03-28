#!/usr/bin/env bash
set -euo pipefail

# capsper-launcher.sh — LaunchAgent entry point for macOS
#
# Called by the LaunchAgent plist instead of the binary directly.
# Applies any pending update (symlink swap + validation), then exec's capsper.
# This mirrors Linux's ExecStartPre= pattern and enables auto-rollback.

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper"

# Apply pending update if one is staged
if [ -f "$INSTALL_DIR/capsper-apply-update.sh" ]; then
    bash "$INSTALL_DIR/capsper-apply-update.sh"
fi

# Exec the binary with all arguments passed through from the plist
exec "$@"
