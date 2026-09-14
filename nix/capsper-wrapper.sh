#!@shell@
# shellcheck shell=bash disable=SC2239
# Wrapper installed as bin/capsper by the Nix package.
#
# capsper's built-in default for --model is "../models/nemotron" resolved
# against its own executable directory (src/main.zig). Under Nix that lands
# inside the read-only store, where models can never be downloaded, so default
# it to a writable data directory instead.
#
# An explicit --model on the command line still wins: capsper's argument
# parser takes the last occurrence, and the caller's arguments come after
# ours. CAPSPER_MODEL_DIR overrides the default without needing a flag.
set -euo pipefail

model_dir="${CAPSPER_MODEL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/capsper/models/nemotron}"

exec @exe@ --model "$model_dir" "$@"
