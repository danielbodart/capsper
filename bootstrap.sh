#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export MISE_DATA_DIR="$SCRIPT_DIR/tools"
export MISE_INSTALL_PATH="$MISE_DATA_DIR/mise"
export MISE_INSTALL_HELP=0
export MISE_GLOBAL_CONFIG_FILE=/dev/null
export PATH="$MISE_DATA_DIR:$PATH"

http() { curl --progress-bar "$@" || wget -qO- "$@"; }

[[ -f "$MISE_INSTALL_PATH" ]] || http https://mise.run | sh
git -C "$SCRIPT_DIR" submodule update --init --recursive --quiet
command -v git-lfs &>/dev/null && git lfs install --local
mise trust --quiet "$SCRIPT_DIR"
mise install
eval "$(mise env)"

# If this script is being executed (not sourced) and has an argument, run it with bun
[[ "${BASH_SOURCE[0]}" == "${0}" && -n "${1}" ]] && exec bun "$@"
