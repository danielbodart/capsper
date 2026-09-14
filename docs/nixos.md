# NixOS

capsper ships a flake for NixOS. It is an alternative to `install.sh`, not a
replacement — the tarball installer remains the path for Ubuntu, Arch, Fedora
and macOS, and is unaffected by anything here.

Both packages are **built from source**. Nothing is patchelf'd: the executable
is linked by Zig, which sets its own ELF interpreter and RPATH.

## What the flake provides

| Output | What it is |
|---|---|
| `packages.x86_64-linux.capsper` | The binary, built against nixpkgs' onnxruntime. Free, fully cached. The `default`. |
| `nixosModules.default` | `services.capsper` — uinput, udev, group membership. |
| `homeModules.default` | `services.capsper` — the user service itself. |
| `checks.x86_64-linux.nixos-module` | Boots NixOS in a VM and asserts the module's permissions. |

Unlike the release tarball, these are not built for `x86_64_v3`, so they run on
any x86_64 machine.

## Why there is no GPU build

capsper ran an NVIDIA/CUDA variant until it was measured against the CPU one
and found not to be worth its cost. On the regression suite the two are within
noise of each other on accuracy, and the CPU build transcribes about 8x faster
than real time -- far more headroom than push-to-talk needs.

What it cost was battery. NVIDIA's finegrained runtime power management is
all-or-nothing: the discrete GPU drops to D3cold, which powers the device off,
and any process holding a CUDA context pins it `active` instead. Measured on an
RTX 4070 Laptop with the model resident and no audio being sent, the GPU clocks
down to 210MHz and idles at ~3.5W (837MiB VRAM, 0% utilisation) -- paid
continuously, where the CPU build's ~1.4 cores are paid only while you speak.
Idling at 3.5W for sixteen hours is ~56Wh, against a couple of Wh for half an
hour of dictation.

Suspending the GPU between presses was not a way out: the model lives in VRAM
and D3cold discards it, so the session had to be rebuilt from scratch --
measured at 2.5-3.0s from a warm page cache, against ~2.0s for the CPU build.
Three seconds before the first word is not a usable dictation latency, and
CUDA offers no way to keep a session alive while releasing the device.

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
  settings = {
    trigger.key = "capslock";
    audio = {
      target = "vocaster_hostmic";
      channel = "FL";
      gain = 10.0;
    };
    # meeting.enabled, tcp.port, debug_recording.dir ...
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

### The console's settings page, here

Capsper's console can edit the settings and save them, and on NixOS it cannot.
The file it would write is the store path this module built, which is read-only
by design and would be replaced by the next rebuild even if it were not.

So it does not pretend. Pressing Save on a NixOS machine changes nothing,
capsper keeps running, and the page hands back the ZON the form produced —
naming only what differs from the defaults — for you to transcribe into
`settings` here. The translation is mechanical: a ZON field becomes a Nix
attribute, and a ZON enum literal becomes the plain string this module's
renderer turns back into one.

Everything else the console does works normally: it is reading, and reading is
not the part the store path forbids.

## Models

The models are **not** in the Nix store. They are ~900MB, versioned
independently of capsper, and already addressed by a runtime flag, so keeping
them in a mutable data directory avoids a 900MB closure that changes every time
the weights do.

```bash
M=~/.local/share/capsper/models/nemotron
B=https://huggingface.co/danielbodart/nemotron-speech-600m-onnx/resolve/main
mkdir -p "$M"
for f in int8-dynamic/encoder_model.onnx int8-dynamic/encoder_model.onnx.data \
         int8-dynamic/decoder_model.onnx int8-dynamic/decoder_model.onnx.data \
         shared/filterbank.bin shared/tokens.txt config.json; do
  curl -fSL -o "$M/$(basename "$f")" "$B/$f"
done
```

`bin/capsper` is a wrapper that defaults `--model` to
`$XDG_DATA_HOME/capsper/models/nemotron`, because capsper's own default is
resolved relative to its executable and would land inside the read-only store.
Override with `CAPSPER_MODEL_DIR`, an explicit `--model`, or the module's
`modelDir` option.

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

Nothing here is pinned to a released artefact: the package is built from the
source the flake points at, against nixpkgs' own onnxruntime.

### Which version you end up running

`capsper --version` reports `0.<commits>.<build>`, the same shape the release
binaries carry, so a Nix build and a tarball build can be compared directly.
Nix takes the commit count from the flake input and uses the commit date as
the build stamp, where a release uses the CI run number:

```
0.392.20260914141256   # nix, at commit 392, committed 14 Sep 14:12:56
0.392.481              # the release built from that same commit by CI
```

The commit count only reaches the build if the input is a **git** ref.
`github:danielbodart/capsper` fetches a tarball through GitHub's API, which
carries the revision but not the count, and lands on `0.0.<date>`. If you want
the number, ask for git:

```nix
capsper = {
  url = "git+https://github.com/danielbodart/capsper";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

That clones the history rather than fetching a tarball — a little slower to
fetch and to update, which is the whole of the trade.

## Which onnxruntime

The package links nixpkgs' own `onnxruntime`, which is in `cache.nixos.org` and
needs no build. That is 1.24.4, while the release tarball ships 1.23.2 --
verified equivalent: the full long regression group produces identical coverage
and WER on both.

## Notes

**The build.zig options this relies on.** `-Dort-include` / `-Dort-lib` point
at an external onnxruntime, `-Drpath` adds RPATH entries for libraries at
absolute store paths, and `-Dprop-tests=false` drops the only external Zig
dependency so the build needs no network in the sandbox. All three default to
the previous behaviour, so the tarball build is unchanged.

**Git LFS.** `dist/linux/lib/*.so` are LFS objects and arrive as pointer files
when the flake is fetched from GitHub. The source filter excludes that
directory entirely; nothing in the Nix build reads it.
