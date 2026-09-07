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

# Empty for the CPU build, which resolves everything through its own RUNPATH.
# The CUDA build needs it: ONNX Runtime dlopens its execution providers by
# bare filename, and those in turn need the CUDA runtime -- neither of which
# is visible to the RUNPATH of the executable, since RUNPATH is not consulted
# for a dependency's own dependencies.
extra_lib_path="@libpath@"

if [ -n "$extra_lib_path" ]; then
    # libcuda.so.1 belongs to the NVIDIA driver, not to any package. On NixOS
    # it is at /run/opengl-driver/lib, which is already baked in below. On any
    # other distro running Nix (Ubuntu, Mint, Fedora) it is somewhere like
    # /usr/lib/x86_64-linux-gnu, so point CAPSPER_DRIVER_LIB at it -- or use
    # nixGL, which works this out for you.
    #
    # It is deliberately opt-in rather than guessed: everything on
    # LD_LIBRARY_PATH is searched ahead of RUNPATH, so blindly adding a host
    # library directory would let the system's glibc or libstdc++ shadow the
    # ones this build was linked against.
    export LD_LIBRARY_PATH="${extra_lib_path}${CAPSPER_DRIVER_LIB:+:$CAPSPER_DRIVER_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

exec @exe@ --model "$model_dir" "$@"
