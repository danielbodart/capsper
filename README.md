<p align="center">
  <img src="logo.png" alt="CAPSPER!" width="400">
</p>

Does CapsLock annoy you? Ever wished it actually did something useful instead of SHOUTING AT PEOPLE BY ACCIDENT?

Ever wished you could just whisper to a friendly ghost and have your words appear on screen? Well now you can. Capsper is your friendly neighbourhood ghost writer — hold CapsLock, speak, and he types it out for you. No cloud, no subscription, no latency worth complaining about. Just a local GPU (or CPU), a haunted key, and a little whisper magic.

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

- Debian/Ubuntu (or similar)
- PipeWire (default audio server on modern Ubuntu/Fedora)
- **GPU (recommended):** NVIDIA GPU with ~2 GB VRAM (Turing or newer: GTX 16xx, RTX 20xx/30xx/40xx/50xx), NVIDIA drivers, and cuDNN
- **CPU-only:** works without a GPU (slower, but functional)

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
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.capsper.capsper.plist
```

Hold CapsLock and speak. Release to stop. Text appears in the focused window. CapsLock is the default trigger — you can use any key with `--trigger` (see [Server options](#server-options)).

## Auto-updates

Capsper can optionally check for updates daily (the installer offers to set this up). When a new version is found, it's downloaded and staged in the background. The update is applied automatically on the next service restart — capsper is never interrupted mid-session.

Check for updates manually:

```bash
~/.local/share/capsper/capsper-update.sh
```

Apply a staged update:

```bash
# Linux
systemctl --user restart capsper.service

# macOS
launchctl bootout gui/$(id -u)/com.capsper.capsper 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.capsper.capsper.plist
```

If a new version crashes repeatedly (3 times within 60 seconds), capsper automatically rolls back to the previous version (Linux). You can also roll back manually:

```bash
~/.local/share/capsper/capsper-rollback.sh --force

# Linux
systemctl --user reset-failed capsper.service
systemctl --user start capsper.service
```

Disable auto-updates:

```bash
# Linux
systemctl --user disable --now capsper-update.timer

# macOS
launchctl bootout gui/$(id -u)/com.capsper.update
```

### Drop terms

Capsper's RNNT model sometimes emits short filler phrases (e.g. "Thank you.", "I love you") on segments with no real speech. You can suppress these by providing a drop terms file:

```bash
capsper --trigger capslock --drop-terms ~/my-drop-terms.txt
```

The file is one phrase per line. If the entire output of a single decode cycle exactly matches a drop term, it's silently suppressed. Matching is case-sensitive and includes punctuation.

Example `my-drop-terms.txt`:
```
Thank you.
I love you
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

  --model, -m PATH          Model directory path (default: ../models/nemotron relative to binary)
  --port, -p PORT           TCP port (default: 43007, use 0 for OS-assigned)
  --input tcp|local         Input mode: tcp (socket) or local (audio capture)
  --trigger KEY             Trigger key for push-to-talk (default: none)
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
  --warmup-file FILE        WAV file for inference warmup at startup
  --no-warmup               Skip warmup inference
  --verbose, -v             Enable verbose logging
  --dry-run                 Load models, run warmup, then exit (validates setup)
  --version                 Print version and exit
```

## Development

Want to hack on Capsper? You'll need the [requirements](#requirements) for your platform.

```bash
git clone https://github.com/danielbodart/capsper.git
cd capsper
./run.ts
```

This auto-detects your platform and handles everything:
- Installs toolchain (mise, Zig 0.15, Bun) on first run via `bootstrap.sh`
- Installs system packages (`libpipewire-0.3-dev`, `pv`, `ncat` on Linux; `shellcheck` on macOS)
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

**"Failed to init input handler"** — Accessibility permission not granted. Open System Settings > Privacy & Security > Accessibility and add capsper (or Terminal).

**No audio captured** — Microphone permission not granted. Open System Settings > Privacy & Security > Microphone and add capsper (or Terminal).

**Service not starting** — check logs with `tail -f ~/.local/share/capsper/capsper.log`. Ensure both Accessibility and Microphone permissions are granted.

### Both platforms

**Keyboard locked up** — press Enter+Backspace+Escape simultaneously to trigger the panic sequence and ungrab all keyboards.

**"Failed to load model"** — model files not found. Re-run `./install.sh` to download models, or download manually from HuggingFace.

## Acknowledgements

Capsper uses NVIDIA's [Nemotron Speech 600M](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (FastConformer RNNT) model for speech recognition. The model is converted to ONNX and CoreML formats for cross-platform deployment.
