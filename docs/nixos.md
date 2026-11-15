# NixOS

capsper ships a flake for NixOS. It is an alternative to `install.sh`, not a
replacement — the tarball installer remains the path for Ubuntu, Arch, Fedora
and macOS, and is unaffected by anything here.

The package is **the release's own Linux tarball**, not a build from source:
the binary CI built with mise's Zig, tested and released, fetched by its hash
and patched for NixOS by `autoPatchelfHook`, which changes only its ELF
interpreter and RPATHs (`nix/package.nix`). It carries the onnxruntime the
tarball does, and Opus compiled in; PipeWire, libstdc++ and glibc come from
your nixpkgs.

## What the flake provides

| Output | What it is |
|---|---|
| `packages.x86_64-linux.capsper` | The release binary, patched for NixOS. The `default`. Only at a release tag. |
| `nixosModules.default` | `services.capsper` — uinput, udev, group membership. |
| `homeModules.default` | `services.capsper` — the user service itself. |
| `checks.x86_64-linux.nixos-module` | Boots NixOS in a VM and asserts the module's permissions. |

Like the tarball, the binary is built for `x86_64_v3` (Haswell or later).

There is a package only at a **release tag**: a release's tag is a commit of
its own, a child of the released trunk commit, that adds `nix/release.json`
(the version, and the tarball's URL and hash), because a flake fetched as
`github:danielbodart/capsper/v<V>` sees its commit but not its tag. Trunk has
no such file, so it has the modules and checks but no package: pin a tag.

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
  url = "github:danielbodart/capsper/v<V>";   # a release tag, from the Releases page
  inputs.nixpkgs.follows = "nixpkgs";
};
```

`follows` is **recommended** here. capsper's largest runtime dependency is
PipeWire, whose closure is ~700MB once you count the SPA plugins (libcamera,
gstreamer, ffmpeg). Any machine that can run capsper already has PipeWire, so
following your nixpkgs means that cost is shared rather than duplicated — and
it can only be shared if both resolve to the same store path. Following is
safe: the release binary is patched against your nixpkgs, and asks of its glibc
and PipeWire no more than any distribution's.

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
does. Updating is moving the input to a newer release tag:

```bash
# in your flake.nix: capsper.url = "github:danielbodart/capsper/v<newer>";
nix flake update capsper
sudo nixos-rebuild switch --flake .
# and if it misbehaves:
sudo nixos-rebuild switch --rollback
```

`capsper --version` reports the release's own `0.<commits>.<build>`, the same
as the tarball's, since it is the same binary.

## Which onnxruntime

The release tarball's own: `vendor/onnxruntime/lib`, 1.23.2, the library the
binary was built and regression-tested against, patched to find nixpkgs'
libstdc++ and libgcc_s. (Until the package became the release tarball it was
built from source against nixpkgs' onnxruntime, 1.24.4, which the long
regression group showed to give identical coverage and WER.)

## Notes

**How CI checks the package before a release.** CI's nix job takes the
tarball its own linux job built and makes it the flake's release
(`scripts/nix-local-release.sh`: it writes `nix/release.json` for it, stages
it, and adds the tarball to the store at the path `fetchurl` would fetch it
to), so `nix flake check` runs the very binary that run releases, through the
same package a pinned tag gives. To do the same locally after `mise run dist`:
`scripts/nix-local-release.sh "$(./run version)" dist && ./run nix`, then
`git rm --cached -f nix/release.json`; it must never be committed to trunk.

**build.zig's external-library options** (`-Dort-include`, `-Dort-lib`,
`-Drpath`, `-Dsystem-opus`, `-Dprop-tests=false`) were for the source build
the flake used to make. Nothing in this repository uses them now; they remain
for anyone packaging capsper from source against their own libraries.
