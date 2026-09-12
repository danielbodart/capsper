# NixOS

capsper ships a flake for NixOS. It is an alternative to `install.sh`, not a
replacement — the tarball installer remains the path for Ubuntu, Arch, Fedora
and macOS, and is unaffected by anything here.

Both packages are **built from source**. Nothing is patchelf'd: the executable
is linked by Zig, which sets its own ELF interpreter and RPATH.

## What the flake provides

| Output | What it is |
|---|---|
| `packages.x86_64-linux.capsper-cpu` | CPU inference, against nixpkgs' onnxruntime. Free, fully cached. The `default`. |
| `packages.x86_64-linux.capsper-cuda` | NVIDIA GPU inference. Unfree; adds the CUDA runtime. |
| `nixosModules.default` | `services.capsper` — uinput, udev, group membership. |
| `homeModules.default` | `services.capsper` — the user service itself. |
| `checks.x86_64-linux.nixos-module` | Boots NixOS in a VM and asserts the module's permissions. |

Unlike the release tarball, these are not built for `x86_64_v3`, so they run on
any x86_64 machine.

## Which variant on a laptop

`capsper-cpu`, in most cases — and the reason is battery, not speed.

NVIDIA's finegrained runtime power management is all-or-nothing: the discrete
GPU drops to D3cold, which powers the device off, and any process holding a
CUDA context pins it `active` instead. So an always-on `capsper-cuda` keeps the
GPU out of D3cold for as long as the service runs.

That is less dramatic than it sounds. Measured on an RTX 4070 Laptop with the
model resident and no audio being sent, the GPU clocks itself down to 210MHz
and idles at **~3.5W** (837MiB VRAM, 0% utilisation). But it is paid
continuously, whereas the CPU build's cost is paid only while you speak:

| | while speaking | while idle |
|---|---|---|
| `capsper-cpu` | ~1.4 cores | GPU suspended, 0W |
| `capsper-cuda` | ~0.6 cores | ~3.5W, indefinitely |

The CPU cost scales with how much you dictate; the GPU idle cost does not.
Idling at 3.5W for sixteen hours is ~56Wh, against a couple of Wh for half an
hour of dictation on CPU. For push-to-talk, which is intermittent by
definition, that is decisive. On a desktop, where the idle watts do not matter,
`capsper-cuda` is the better choice.

**Suspending the GPU between presses is not a way out.** The model lives in
VRAM and D3cold discards it, so the session has to be rebuilt from scratch:
measured at 2.5-3.0s from a warm page cache, against ~2.0s for the CPU build.
Three seconds before the first word is not a usable dictation latency, and
there is no partial version — building the session *is* the expensive part, and
CUDA offers no way to keep one alive while releasing the device.

## Install

Two modules, because capsper straddles the system/user boundary. The system
module grants permissions a user cannot grant themselves; the home-manager
module runs the service, because capsper grabs the keyboards of a login session
and talks to that user's PipeWire.

In your flake inputs:

```nix
capsper = {
  url = "github:danielbodart/capsper";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

`follows` is **recommended** here. capsper's largest runtime dependency is
PipeWire, whose closure is ~700MB once you count the SPA plugins (libcamera,
gstreamer, ffmpeg). Any machine that can run capsper already has PipeWire, so
following your nixpkgs means that cost is shared rather than duplicated — and
it can only be shared if both resolve to the same store path. Because these are
source builds rather than prebuilt binaries, following is safe: the code is
compiled against whatever nixpkgs you hand it.

In your NixOS configuration:

```nix
imports = [ inputs.capsper.nixosModules.default ];

services.capsper = {
  enable = true;
  users = [ "dan" ];   # adds them to the input and uinput groups
};
```

In your home-manager configuration:

```nix
imports = [ inputs.capsper.homeModules.default ];

services.capsper = {
  enable = true;
  # Defaults to capsper-cpu. Swap in capsper-cuda on a desktop -- see
  # "Which variant on a laptop" above for why that is the wrong way round
  # on battery.
  package = inputs.capsper.packages.x86_64-linux.capsper-cuda;

  settings = {
    trigger.key = "capslock";
    audio = {
      target = "vocaster_hostmic";
      channel = "FL";
      gain = 10.0;
    };
    # meeting.enabled, tcp_server.port, debug_recording.dir ...
  };
};
```

Group membership only takes effect on the next login, so log out and back in
after the first `nixos-rebuild switch`.

Run `capsper --audio-detect` once to find the right `audio.channel` and
`audio.gain` for your microphone, then put them in the config.

### Settings

`settings` is capsper's own `Config`, from `src/shared/config.zig`, written as
a Nix attribute set. The module renders it to the ZON file capsper reads and
passes `--config`. There is no option per flag: the flags cover only the part
of the settings that predates the config file, so meeting capture, the voice
activity gate and echo cancellation had no way to be set from here at all.

Anything left out keeps capsper's default rather than one chosen by this
module, so the rendered file names only what you set.

Enum-valued settings are plain strings — `trigger.key = "capslock"`,
`audio.channel = "FR"` — and the renderer turns them into ZON enum literals.
It knows which settings those are from a list in `nix/to-zon.nix`; for an enum
added to capsper since, `capsper.lib.zon.tag "value"` says so at the point of
use.

The rendered file is parsed by capsper during the build, so a misspelled field
or an invalid value fails `nixos-rebuild` with capsper's own diagnostic rather
than leaving a service that will not start.

To move an existing command line over, let capsper do it:

```bash
capsper --trigger capslock --audio-target vocaster_hostmic --audio-gain 10 \
        --write-config
```

It prints the settings those flags mean, naming only what differs from the
defaults, which transcribes straight into `settings`.

`extraArgs` still appends flags to the command line. Flags are applied over the
file, so anything there wins over `settings` for that one setting.

## Models

The models are **not** in the Nix store. They are ~900MB, versioned
independently of capsper, and already addressed by a runtime flag, so keeping
them in a mutable data directory avoids a 900MB closure that changes every time
the weights do.

```bash
M=~/.local/share/capsper/models/nemotron
B=https://huggingface.co/danielbodart/nemotron-speech-600m-onnx/resolve/main
mkdir -p "$M"
# int8-static for NVIDIA GPUs; int8-dynamic for CPU-only machines.
for f in int8-static/encoder_model.onnx int8-static/encoder_model.onnx.data \
         int8-static/decoder_model.onnx int8-static/decoder_model.onnx.data \
         shared/filterbank.bin shared/tokens.txt config.json; do
  curl -fSL -o "$M/$(basename "$f")" "$B/$f"
done
```

`bin/capsper` is a wrapper that defaults `--model` to
`$XDG_DATA_HOME/capsper/models/nemotron`, because capsper's own default is
resolved relative to its executable and would land inside the read-only store.
Override with `CAPSPER_MODEL_DIR`, an explicit `--model`, or the module's
`modelDir` option.

## GPU on a non-NixOS host

`libcuda.so.1` belongs to the NVIDIA driver rather than to any package. On
NixOS it lives at `/run/opengl-driver/lib`, which the wrapper already searches.
On another distro running Nix — Ubuntu, Mint, Fedora — point
`CAPSPER_DRIVER_LIB` at wherever the driver put it:

```bash
CAPSPER_DRIVER_LIB=/usr/lib/x86_64-linux-gnu capsper --dry-run
```

or use [nixGL](https://github.com/nix-community/nixGL), which works it out for
you. It is opt-in rather than guessed because everything on `LD_LIBRARY_PATH`
is searched ahead of RPATH, so blindly adding a host library directory would
let the system's glibc or libstdc++ shadow the ones the build was linked
against.

## Updating

There is no auto-update, and none of `capsper-update.sh`,
`capsper-apply-update.sh`, `capsper-rollback.sh` or the daily timer are
installed. Under Nix they would be both redundant and inert — the store is
read-only, and atomic switch plus rollback is what `nixos-rebuild` already
does. Because the packages build from source, the flake tracks the repository
rather than a release, so there are no hashes to bump:

```bash
nix flake update capsper
sudo nixos-rebuild switch --flake .
# and if it misbehaves:
sudo nixos-rebuild switch --rollback
```

The one pinned artefact is the onnxruntime build used by `capsper-cuda` (see
below); its URL and hash live in `nix/package.nix` and only change when the ORT
version does.

## Why the CUDA variant fetches onnxruntime

`capsper-cpu` links nixpkgs' own `onnxruntime`, which is in `cache.nixos.org`
and needs no build. `capsper-cuda` cannot: it needs the CUDA execution
provider, and `onnxruntime` with `cudaSupport` is in **no** binary cache —
not `cache.nixos.org`, not `cuda-maintainers.cachix.org`, not
`nix-community.cachix.org`. Building it means a multi-hour compile repeated on
every nixpkgs bump that touches gcc, glibc or the CUDA packages, to arrive at a
*different* ORT build from the one capsper's regression thresholds were tuned
against.

So `capsper-cuda` fetches the onnxruntime that capsper's own CI publishes. That
is a `fetchurl`, hence a fixed-output derivation, so nixpkgs bumps do not
invalidate it. The libraries are unpacked untouched (`dontFixup`) and located
at runtime through `LD_LIBRARY_PATH` in the wrapper rather than by rewriting
them — a shared library has no ELF interpreter, so nothing about them *has* to
be rewritten.

Note the CPU variant runs against ORT 1.24.4 while the release tarball ships
1.23.2. Verified equivalent: the full long regression group produces identical
coverage and WER on both.

## Notes

**The build.zig options this relies on.** `-Dort-include` / `-Dort-lib` point
at an external onnxruntime, `-Drpath` adds RPATH entries for libraries at
absolute store paths, and `-Dprop-tests=false` drops the only external Zig
dependency so the build needs no network in the sandbox. All three default to
the previous behaviour, so the tarball build is unchanged.

**Git LFS.** `dist/linux/lib/*.so` are LFS objects and arrive as pointer files
when the flake is fetched from GitHub. The source filter excludes that
directory entirely; nothing in the Nix build reads it.
