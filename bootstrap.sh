#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
TOOLS_ROOT=$(git -C "$SCRIPT_DIR" worktree list 2>/dev/null | head -1 | awk '{print $1}')
export MISE_DATA_DIR="${TOOLS_ROOT:-$SCRIPT_DIR}/tools"
export MISE_INSTALL_PATH="$MISE_DATA_DIR/mise"
export MISE_INSTALL_HELP=0
# Keep the build hermetic by overriding the user's personal global mise config
# with the project's own .mise.toml (rather than /dev/null — mise >= 2026.8.x
# parses this path by file type and errors on /dev/null, breaking install).
export MISE_GLOBAL_CONFIG_FILE="$SCRIPT_DIR/.mise.toml"
export ZIG_GLOBAL_CACHE_DIR="$MISE_DATA_DIR/zig-cache"
export PATH="$MISE_DATA_DIR:$PATH"

http() { curl --progress-bar "$@" || wget -qO- "$@"; }

# ─── macOS prerequisites ──────────────────────────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
    if ! command -v brew &>/dev/null; then
        echo "ERROR: Homebrew is required on macOS. Install from https://brew.sh"
        [[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 1 || return 1
    fi

    # Ensure git-lfs and cmake are available
    _brew_missing=()
    command -v git-lfs &>/dev/null || _brew_missing+=(git-lfs)
    command -v cmake &>/dev/null || _brew_missing+=(cmake)
    if (( ${#_brew_missing[@]} )); then
        echo "Installing missing brew packages: ${_brew_missing[*]}"
        brew install "${_brew_missing[@]}"
    fi

    # Check for full Xcode (needed for Metal shader compilation)
    if ! xcrun metal --version &>/dev/null; then
        echo ""
        echo "=== Xcode Required ==="
        echo "Full Xcode.app is needed for Metal shader compilation."
        echo ""
        echo "Option 1: App Store GUI or website (required for first-time install)"
        echo "  Open App Store → search 'Xcode' → Install"
        echo "  Or download from: https://developer.apple.com/xcode/"
        echo ""
        echo "Option 2: Command line (only works if Xcode was previously installed)"
        echo "  brew install mas && mas install 497799835"
        echo ""
        echo "After installing Xcode:"
        echo "  sudo xcodebuild -license accept"
        echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        echo "  xcodebuild -downloadComponent MetalToolchain  (NO sudo — per-user install)"
        echo ""
        # Don't abort — Xcode is only needed for rebuild-libs, not for building
        # against pre-built dylibs
    fi
fi

# ─── NixOS: re-enter through the flake's dev shell ────────────────────────
# The build needs pkg-config, PipeWire's headers and a couple of binaries the
# dist step shells out to. Every other Linux gets those from apt; there is no
# apt here, so the flake supplies them instead and this re-runs the same
# command inside that shell. CAPSPER_DEV_SHELL is what stops it recursing.
#
# Only the system half comes from Nix. mise still installs the toolchain
# below, so the zig and bun that build the binary are the versions .mise.toml
# pins -- exactly what CI uses.
if [[ -z "${CAPSPER_DEV_SHELL:-}" && -e /etc/NIXOS && "${BASH_SOURCE[0]}" == "${0}" ]]; then
    export CAPSPER_DEV_SHELL=1
    exec nix develop "$SCRIPT_DIR" \
        --extra-experimental-features 'nix-command flakes' \
        --command "$0" "$@"
fi

# ─── Common setup ─────────────────────────────────────────────────────────
[[ -f "$MISE_INSTALL_PATH" ]] || http https://mise.run | sh
git -C "$SCRIPT_DIR" submodule update --init --recursive --quiet
command -v git-lfs &>/dev/null && git lfs install --local && git -C "$SCRIPT_DIR" lfs pull
mise trust --quiet "$SCRIPT_DIR"
mise install
eval "$(mise env)"

# If this script is being executed (not sourced) and has an argument, run it with bun
[[ "${BASH_SOURCE[0]}" == "${0}" && -n "${1}" ]] && exec bun "$@"
