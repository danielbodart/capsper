<p align="center">
  <img src="logo.png" alt="CAPSPER!" width="400">
</p>

Does CapsLock annoy you? Ever wished it actually did something useful instead of SHOUTING AT PEOPLE BY ACCIDENT?

Ever wished you could just whisper to a friendly ghost and have your words appear on screen? Well now you can. Capsper is your friendly neighbourhood ghost writer — hold CapsLock, speak, and he types it out for you. No cloud, no subscription, no latency worth complaining about. Just a local GPU (or CPU), a haunted key, and a little ~~whisper~~ nemo magic.

Push-to-talk voice dictation for Linux and macOS. Uses NVIDIA's [Nemotron Speech 600M](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) model (FastConformer RNNT) for streaming speech-to-text. Single self-contained binary per platform.

## How it works

1. A single binary intercepts CapsLock as push-to-talk
2. Audio is captured directly from the system audio while the trigger key is held
3. Incremental transcription runs locally via the Nemotron RNNT model
4. Transcribed text is injected as keystrokes into the focused window

| | Linux | macOS |
|---|---|---|
| **Keyboard** | evdev grab + uinput virtual keyboard | CGEventTap + CGEventPost |
| **Audio** | PipeWire capture | CoreAudio (AUHAL) |
| **Inference** | ONNX Runtime (CUDA or CPU) | CoreML (93% Apple Neural Engine) |
| **Display server** | X11 and Wayland | native |

## Requirements

### Linux

- Debian/Ubuntu/NixOS (or similar)
- PipeWire (default audio server on modern Ubuntu/Fedora)
- **GPU (recommended):** NVIDIA GPU with ~4 GB VRAM (Turing or newer: GTX 16xx, RTX 20xx/30xx/40xx/50xx), NVIDIA drivers, and cuDNN — near-zero CPU impact during inference
- **CPU-only:** works without a GPU at similar speed, but uses significant CPU while speaking

### macOS

- Apple Silicon Mac (M1 or later)
- macOS 13 (Ventura) or later
- Accessibility and Microphone permissions (the installer walks you through this)

## Install

### Linux

```bash
mkdir capsper && cd capsper
curl -fSL https://github.com/danielbodart/capsper/releases/latest/download/capsper-linux-x86_64.tar.gz | tar -xz
./install.sh
```

### NixOS

NixOS has its own flake, since the tarball installer's assumptions (a writable install prefix, `usermod`, hand-written udev rules, self-updating binaries) do not hold there:

```nix
inputs.capsper.url = "github:danielbodart/capsper";
```

See [docs/nixos.md](docs/nixos.md) for the NixOS and home-manager modules, and for how to fetch the models.

### macOS

```bash
mkdir capsper && cd capsper
curl -fSL https://github.com/danielbodart/capsper/releases/latest/download/capsper-macos-arm64.tar.gz | tar -xz
./install.sh
```

The installer walks you through everything interactively — downloading models, setting up permissions, detecting your microphone, and installing a background service.

On Linux, a launcher script automatically detects whether you have an NVIDIA GPU and runs the appropriate binary (`capsper-cuda` or `capsper-cpu`).

## Usage

### Linux

```bash
systemctl --user start capsper.service
```

### macOS

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.danielbodart.capsper.plist
```

Hold CapsLock and speak. Release to stop. Text appears in the focused window. CapsLock is the default trigger — you can change it with `--trigger` (see [Trigger keys](#trigger-keys)).

## Auto-updates

On Linux, capsper can optionally check for updates daily (the installer offers to set this up). When a new version is found, it's downloaded and staged in the background. The update is applied automatically on the next service restart — capsper is never interrupted mid-session.

On macOS, auto-updates are not yet available — updating the binary invalidates Accessibility permission because macOS identifies ad-hoc signed binaries by hash. To update manually, re-download and run `install.sh`, then re-approve capsper in System Settings > Accessibility.

Check for updates manually (Linux):

```bash
~/.local/share/capsper/capsper-update.sh
```

Apply a staged update (Linux):

```bash
systemctl --user restart capsper.service
```

If a new version crashes repeatedly (3 times within 60 seconds), capsper automatically rolls back to the previous version (Linux). You can also roll back manually:

```bash
~/.local/share/capsper/capsper-rollback.sh --force
systemctl --user reset-failed capsper.service
systemctl --user start capsper.service
```

Disable auto-updates (Linux):

```bash
systemctl --user disable --now capsper-update.timer
```

### Drop terms

Unlike Whisper, the Nemotron RNNT model doesn't automatically suppress filler words like "um" and "uh". You can suppress these (and other unwanted phrases) by providing a drop terms file:

```bash
capsper --trigger capslock --drop-terms ~/my-drop-terms.txt
```

The file is one phrase per line. If the entire output of a single decode cycle exactly matches a drop term, it's silently suppressed. Write terms in lowercase (the model always outputs lowercase text).

Example `my-drop-terms.txt`:
```
uh
um
you know
```

### Audio setup (Linux)

Run the interactive setup wizard to detect your microphone channel and calibrate gain:

```bash
capsper --audio-detect
```

This lists available audio sources, lets you pick a device, records silence and speech to detect the best channel, then calibrates software gain. At the end it prints the recommended flags:

```
  --audio-channel FL --audio-gain 3.2
```

If you already know your device, skip the selection step:

```bash
capsper --audio-detect --audio-target alsa_input.usb-Focusrite_Vocaster...
```

### Debug recording

To diagnose transcription issues (e.g. dropped words), enable per-utterance recording:

```bash
mkdir /tmp/capsper-debug
capsper --trigger capslock --record-dir /tmp/capsper-debug
```

Each utterance produces a pair of files (`000.wav`/`000.log`, `001.wav`/`001.log`, etc.) in a ring buffer — old files are overwritten after `--record-keep` pairs (default 10). The WAV contains the full utterance audio and the log contains emitted text plus a per-cycle diagnostic trace.

Batch-transcribe a captured WAV to compare streaming vs non-streaming results:

```bash
capsper --transcribe /tmp/capsper-debug/005.wav
```

This loads the model, transcribes the entire file in one shot, prints the result, and exits.

## Architecture

Capsper uses NVIDIA's Nemotron Speech 600M model — a FastConformer-based RNNT (Recurrent Neural Network Transducer) that's inherently incremental. Unlike the previous whisper.cpp approach which needed separate voice activity detection and cross-attention tricks for streaming, the RNNT model naturally processes audio as it arrives and emits tokens incrementally. Push-to-talk is the sole gate — no VAD needed.

The model runs through different backends depending on platform:

- **Linux (NVIDIA GPU):** ONNX Runtime with CUDA execution provider — int8-static quantization
- **Linux (CPU):** ONNX Runtime CPU — int8-dynamic quantization
- **macOS (Apple Silicon):** CoreML — FP16, runs 93% on the Apple Neural Engine

A single Zig binary handles everything: keyboard interception, audio capture, mel spectrogram computation, model inference, SentencePiece detokenization, and text injection. No Python, no runtime dependencies beyond the platform's audio system and GPU drivers.

## Server options

Running `capsper` with no arguments prints usage and exits.

```
capsper [OPTIONS]

  --config PATH             Config file (default: $XDG_CONFIG_HOME/capsper/config.zon)
  --model, -m PATH          Model directory path (default: ../models/nemotron relative to binary)
  --port, -p PORT           TCP port (use 0 for OS-assigned; omit for no server)
  --stream FILE             Stream a WAV file through the pipeline and exit
  --trigger KEY             Trigger key for push-to-talk (see Trigger keys below)
  --trigger-passthrough     Forward trigger key to OS after interception
  --type-delay US           Delay between injected keystrokes in microseconds (default: 12000)
  --low-latency             Keep audio stream open (mic indicator always visible, ~300ms faster)
  --audio-target NODE       Audio capture target device name
  --audio-channel CHANNEL   Audio channel: MONO, FL, FR, AUX0-AUX63 (default: FL)
  --audio-gain FACTOR       Software gain multiplier (default: 1.0, max: 10.0)
  --audio-detect            Interactive audio setup wizard (device selection, channel detection, gain calibration)
  --detect-duration SECS    Duration per detection phase (default: 5)
  --drop-terms FILE         Text file of phrases to suppress (one per line, exact match)
  --record-dir DIR          Record each utterance to DIR (WAV + diagnostic log)
  --record-keep N           Number of recording pairs to keep (default: 10, ring buffer)
  --transcribe FILE         Batch-transcribe a WAV file (non-streaming) and exit
  --no-auto-gain            Disable automatic gain adjustment
  --on-device-lost MODE     exit or wait when the capture device disappears (default: wait)
  --verbose, -v             Enable verbose logging
  --dry-run                 Load models, run warmup, then exit (validates setup)
  --version                 Print version and exit
```

An unrecognised flag is a warning, not an error, so a service file carrying a
flag from an older version still starts.

## Config file

Every option above except the one-shot commands can also be set in a config
file, which is where the settings that do not fit comfortably on a command line
live. Flags are applied over the file, so a flag always wins for one run.

Capsper reads `$XDG_CONFIG_HOME/capsper/config.zon`, falling back to
`~/.config/capsper/config.zon`, unless `--config` names another path. A missing
file is not an error; it means defaults. A file that is present but does not
parse stops startup, with the line and column of the problem.

The format is [ZON](https://ziglang.org/documentation/master/#Zig-Object-Notation),
which is what `build.zig.zon` already uses. It has comments, which JSON does
not, and the schema is a Zig type, so an unknown field or a misspelled enum is
a diagnostic rather than a silent default. Every field has a default, so name
only what you want to change.

```zig
.{
    // --model, -m; null means the copy shipped beside the binary
    .model = null,
    .verbose = false,    // --verbose, -v
    .drop_terms = null,  // --drop-terms

    .audio = .{
        .target = null,          // --audio-target; null follows the default source
        .channel = .FL,          // --audio-channel
        .gain = 1.0,             // --audio-gain
        .auto_gain = true,       // --no-auto-gain
        .on_device_lost = .wait, // --on-device-lost
        .detect_duration = 5,    // --detect-duration
    },

    .trigger = .{
        .key = .capslock,        // --trigger; null disables push-to-talk
        .passthrough = false,    // --trigger-passthrough
        .type_delay_us = 12_000, // --type-delay
        .low_latency = false,    // --low-latency
    },

    .tcp_server = .{
        .port = null,            // --port, -p; null means no server
    },

    .debug_recording = .{
        .dir = null,             // --record-dir; null disables
        .keep = 10,              // --record-keep
        .audio_format = .wav,
        .detail = .debug,
    },
}
```

Three names differ from the flag they mirror. `audio.auto_gain` is positive
because a file should not carry negations. `trigger.type_delay_us` carries its
unit, because a bare number in a file has no usage text beside it.
`debug_recording.*` is named for what it is rather than what the flag was.

One-shot actions stay on the command line and have no field: `--version`,
`--dry-run`, `--audio-detect`, `--transcribe`, `--stream`. The `--pw-*` and
`--stream-wav` aliases likewise keep working as flags but have no second
spelling in the file.

## Meeting capture (Linux, in progress)

A second capture mode: continuous, unattended, both sides of a call, one timed
transcript. It is being built in phases and is not finished. What works today
is the audio path.

```zig
.{
    .meeting = .{
        .enabled = true,
        .sink_name = "capsper_transcribe",            // how pw-link addresses it
        .sink_description = "Capsper: Transcribe",    // what the picker shows
        .output = null,                               // null follows your default output
        .near = null,                                 // null follows audio.target
        .dir = "~/.local/share/capsper/sessions",
        .idle_close_seconds = 30,
        .aec = .{ .enabled = true },
    },
}
```

The two names do different jobs. `sink_name` is the identifier: it is what
`pw-link` and `pactl` address, and what the sink is called as a JACK client,
so it stays lowercase and underscored like every `alsa_output.*` beside it.
`sink_description` is the label, is free text, and is what a picker shows. The
monitor takes its own label from it, as "Monitor of Capsper: Transcribe", so
there is nothing to set for the far end.

Change the description whenever you like. Changing `sink_name` is the one to
think about: WirePlumber keys your saved default output on it, and meeting apps
remember a chosen device by it, so a rename drops both back to the system
default without saying so.

With this on, capsper creates a virtual output device of that name. Select it
as the output in the meeting app, and the far end of the call goes into it
instead of your speakers. Capsper passes it straight on to whatever your
default output is, so the call is still audible, and captures it from the
sink's monitor.

A dedicated sink rather than the default output's monitor, because selecting
it *is* the declaration of intent: nothing else is ever in it, so there is no
music or notification audio to filter out afterwards. That selection is also
the arm signal. An application playing into the sink starts a session, and a
session ends once nothing has played into it for `idle_close_seconds` — long
enough that a mute or a screen-share renegotiation does not split one meeting
into two files.

Each session writes a directory:

```
~/.local/share/capsper/sessions/2026/09/11/T143000Z/
  audio.opus   both sides, near left and far right
  audio.vtt    both sides, merged by time
```

The transcript shares the audio file's name, which is the convention media
players use to pair the two, so dropping either into a player picks up both.

Opus at about 48 kbps, which is roughly 20 MB an hour. Twice what one voice
would need, because Opus couples stereo channels efficiently only when they
correlate and these two do not at all — the same total two mono tracks would
have cost. `.audio_format = .wav` instead if you want the raw samples, at
115 MB per channel per hour.

### Echo cancellation

Speakers and an open microphone in one room means the call comes back in a few
tens of milliseconds later, so the near track carries a quieter copy of
everything the far end said and the far end lands in the transcript twice: once
as itself, and once putting words in your mouth. Measured on a real desktop,
with the speakers at ordinary volume and an overhead microphone, the near track
transcribed the far end's speech in full.

`aec.enabled` is on by default and fixes that. The cancellation is WebRTC's
AEC3, running as a PipeWire node rather than a stage inside capsper, and what it
subtracts is capsper's own sink — so it removes the call rather than everything
your speakers happen to be playing. Same room, same measurement, with it on: the
near track is empty and the far track is unchanged, 12.6 dB removed.

It comes up when a session opens and goes away when it closes. Left running it
would schedule the sink alongside its own streams and hold the graph turning
over between calls, which on a laptop is a core spent on nothing.

Only meeting capture is touched. Push-to-talk dictation, its debug recordings
and the TCP server all read the microphone directly, because nothing points them
at the cleaned source. `meeting.near` names the microphone to clean, falling
back to `audio.target`, so dictation and meeting capture can listen to different
inputs — which matters, because they now run at the same time. Mute yourself in
a call, dictate a note into another window, and the meeting goes on recording.

`meeting.output` names where the sink passes the call on to. Unset, it follows
your default output, which is what you want. Naming one is for a machine whose
default is the wrong device, and for tests, which point it at a sink of their
own so they can never make a sound.

The path is a single ISO 8601 timestamp split across directories, in UTC. One
stereo file rather than two mono ones, with the microphone on the left and the
call on the right. Channel separation loses nothing — `ffmpeg` splits them
apart again in one invocation — and what it buys is a single timeline, so the
two sides cannot drift apart from each other or from the transcript.

The transcript is [WebVTT](https://www.w3.org/TR/webvtt1/), which has speaker
attribution in the spec:

```
1
00:00:04.120 --> 00:00:07.880
<v Near>so the thing I wanted to raise was the routing

2
00:00:08.020 --> 00:00:11.400
<v Far>yeah, I looked at that yesterday
```

Two tracks means the speaker is known rather than guessed at by diarisation.
The file drops into any player and shows the transcript against the audio, and
converting it to SRT is a timestamp separator substitution.

### Playing a session back

With meeting capture on, capsper serves its sessions at
[http://127.0.0.1:43008](http://127.0.0.1:43008). The page lists every
recording newest first; picking one plays the audio with the transcript
scrolling in step, near end on the left and far end on the right. Clicking a
line plays from there, and a control sends either channel to both ears so the
hard panning is a choice rather than something to endure.

It binds to loopback, so the recordings are not reachable from the network.
Both the port and the interface are configurable:

```zig
.meeting = .{
    .enabled = true,
    .http = .{
        .port = 43008,        // null disables the server
        .bind = "127.0.0.1",  // "0.0.0.0" to reach it from the network
    },
},
```

### Not paying to transcribe silence

An unattended meeting is mostly one side being quiet while the other talks, and
the ASR encoder costs the same for silence as for speech. A
[Silero](https://github.com/snakers4/silero-vad) voice activity model sits in
front of it, so only audio that sounds like speech is transcribed.

Measured on 28 seconds of audio that is four seconds of speech, twenty seconds
of quiet room tone, then four more seconds of speech:

| | CPU |
|---|---|
| gate on | 10.1 s |
| gate off | 55.6 s |

Both produce the same transcript. The gate never touches the recording — only
the encoder — so the audio still lines up with the cue timestamps, which is the
whole reason it is kept.

```zig
.meeting = .{
    .vad = .{
        .enabled = true,
        .onset = 0.3,           // probability at which speech starts
        .offset = 0.1,          // and under which it may stop
        .min_silence_ms = 1000, // how long it must stay quiet to close
    },
},
```

Two thresholds rather than one, because a single one chatters at the boundary.
Speech starts at `onset` and stops only after staying under `offset` for
`min_silence_ms`, so a breath between sentences keeps the gate open.

Linux only. The CoreML build does not link ONNX Runtime, so there is no gate on
macOS until the model is converted.

Not yet built: Opus. See `docs/meeting-capture-plan.md`. macOS does not support
meeting capture at all, because a program cannot create a virtual output device
for itself there.

### Trigger keys

The `--trigger` flag selects which key activates push-to-talk. CapsLock is the default.

| Key | Linux | macOS | Notes |
|-----|:-----:|:-----:|-------|
| `capslock` | yes | yes | Default. On macOS, remapped to F19 via hidutil to suppress LED/modifier |
| `scrolllock` | yes | yes | On macOS, shares keycode with F14 |
| `numlock` | yes | yes | On macOS, maps to Clear (kVK_ANSI_KeypadClear) |
| `pause` | yes | — | |
| `f13`–`f20` | yes | yes | |
| `f21`–`f24` | yes | — | |

Function keys F13–F20 are the safest choice for a non-default trigger — they exist on both platforms and are rarely used by applications.

## Development

Want to hack on Capsper? You'll need the [requirements](#requirements) for your platform.

```bash
git clone https://github.com/danielbodart/capsper.git
cd capsper
./run.ts
```

This auto-detects your platform and handles everything:
- Installs toolchain (mise, Zig 0.15, Bun) on first run via `bootstrap.sh`
- Installs system packages (`libpipewire-0.3-dev` on Linux; `shellcheck` on macOS)
- On NixOS, where there is no apt, `bootstrap.sh` re-runs the command inside the flake's `devShell`, which supplies that same set plus the CUDA libraries the dev binary loads. The toolchain still comes from mise either way, so a local build uses the versions CI uses
- Downloads models if missing (~250 MB for ONNX, ~150 MB for CoreML)
- Compiles the Zig binary (pre-built ONNX Runtime shared libs committed via Git LFS on Linux)
- Runs unit tests, property tests, and short integration smoke tests

On Linux, `./run.ts build` produces two binaries (`capsper-cuda` + `capsper-cpu`) plus a launcher script. On macOS, it produces a single `capsper` binary using CoreML.

Every step is incremental — re-running `./run.ts` is fast if everything is already set up.

### Building & testing

All commands go through the Bun-based task runner (`run.ts`):

```bash
# Build (default command)
./run.ts build

# Unit + property tests (no GPU required)
./run.ts test

# Regression test groups (requires built binary + model)
./run.ts short-test               # Short files (<15s) via fast-forward TCP
./run.ts medium-test              # Medium files (15-40s) via fast-forward TCP
./run.ts long-test                # Long files (>60s) via fast-forward TCP

# All integration tests (all groups + platform plumbing)
./run.ts slow-test
```

## Troubleshooting

### Linux

**"No CUDA GPU detected"** — the CUDA binary requires an NVIDIA GPU with cuDNN. Ensure NVIDIA drivers are installed (`sudo ubuntu-drivers autoinstall`), that `nvidia-smi` shows your GPU, and that cuDNN is installed. Alternatively, the CPU binary works without a GPU (the launcher script auto-detects this).

**Cannot open /dev/input** — ensure your user is in the `input` group (`groups` to check, `sudo usermod -aG input $USER` then log out/in).

**Text not being typed** — ensure `/dev/uinput` is accessible. The udev rule should be set up by `./install.sh`, or manually: `echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules && sudo udevadm control --reload-rules && sudo udevadm trigger /dev/uinput`.

**Audio capture fails** — ensure PipeWire is running (`pw-cli info`). Run `capsper --audio-detect` to list available sources, select your device, and detect the correct channel.

**Quiet or degraded transcription** — if using a multi-channel audio interface, make sure you're capturing the correct channel. Run `capsper --audio-detect` to detect the best channel and calibrate gain.

### macOS

**"Failed to init input handler"** — Accessibility permission not granted. The capsper *binary itself* must be in the Accessibility list (not just Terminal). Open System Settings > Privacy & Security > Accessibility, click '+', press Cmd+Shift+G, and paste:
```
~/.local/share/capsper/current/bin/capsper
```
If capsper is already in the list, remove it and re-add — macOS caches the permission against the binary hash, so it may need refreshing after an update.

**No audio captured** — Microphone permission not granted. Open System Settings > Privacy & Security > Microphone and add capsper (or Terminal).

**Service not starting** — check logs with `tail -f ~/.local/share/capsper/capsper.log`. Ensure both Accessibility and Microphone permissions are granted for the capsper binary.

### Both platforms

**Keyboard locked up** — press Enter+Backspace+Escape simultaneously to trigger the panic sequence and ungrab all keyboards.

**"Failed to load model"** — model files not found. Re-run `./install.sh` to download models, or download manually from HuggingFace.

## Acknowledgements

Capsper uses NVIDIA's [Nemotron Speech 600M](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (FastConformer RNNT) model for speech recognition. The model is converted to ONNX and CoreML formats for cross-platform deployment.
