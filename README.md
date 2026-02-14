# Zigsper

Push-to-talk voice dictation for Linux. Hold a key, speak, release — text is typed into whatever window is focused.

Uses a custom streaming speech recognition server written in Zig, linking [whisper.cpp](https://github.com/ggml-org/whisper.cpp) for local GPU inference with the `large-v3-turbo` model. Implements [AlignAtt](https://aclanthology.org/2023.findings-emnlp.744/) simultaneous speech processing for low-latency streaming transcription with word-level stability checking.

## How it works

1. A single Zig binary grabs your keyboard via evdev, intercepts CapsLock as push-to-talk
2. Audio is captured directly via PipeWire while the trigger key is held
3. Incremental transcription runs on the GPU with VAD (Silero) and word-level stability checking
4. Transcribed text is injected as keystrokes via uinput into the focused window

## Requirements

- Linux (Debian/Ubuntu)
- NVIDIA GPU with ~4 GB VRAM
- CUDA toolkit (only needed for `rebuild-whisper`; pre-built libs committed via Git LFS)
- PipeWire (default audio server on modern Ubuntu/Fedora)
- User in the `input` group (for evdev keyboard grab and uinput text injection)

## Setup

```bash
git clone --recurse-submodules https://github.com/danielbodart/zigsper.git
cd zigsper
./run
```

This auto-detects and handles everything:
- Installs toolchain (mise, Zig 0.15.2, Bun) on first run via `bootstrap.sh`
- Installs system packages (`pv`, `ncat`)
- Initialises the whisper.cpp submodule if needed
- Downloads models (~574 MB Whisper model + VAD model) if missing
- Compiles the Zig binary (pre-built whisper.cpp shared libs are committed via Git LFS)
- Configures uinput permissions (for text injection via virtual keyboard)
- Creates and enables a systemd user service

Every step is incremental — re-running `./run` is fast if everything is already set up.

## Usage

```bash
systemctl --user start zigsper.service
```

Hold CapsLock and speak. Release to stop. Text appears in the focused window.

### PipeWire channel selection

For multi-channel audio interfaces, first list available sources:

```bash
zigsper --pw-list
```

Then run interactive channel detection to find which channel carries your microphone signal:

```bash
zigsper --pw-detect
# Or target a specific device:
zigsper --pw-detect --pw-target alsa_input.usb-Focusrite_Vocaster...
```

This records silence and speech, then shows per-channel signal levels and recommends the correct `--pw-channel` flag.

## Architecture

```
Physical Keyboard ──evdev──→ zigsper ──uinput──→ Virtual Keyboard → Apps
                              │
                              ├─ Trigger key held → PipeWire audio capture
                              ├─ whisper.cpp (GPU) + Silero VAD
                              ├─ AlignAtt streaming + word-level stability
                              └─ All other keys → forwarded transparently
```

A single self-contained binary (`src/`):

| File | Purpose |
|---|---|
| `main.zig` | Entry point, argument parsing, model loading, warmup |
| `input.zig` | evdev keyboard grab, uinput virtual keyboard, trigger key + text injection |
| `server.zig` | Streaming state machine, word-level delta emission |
| `pipeline.zig` | Low-level whisper.cpp integration, mel/encode/decode loop |
| `alignatt.zig` | Cross-attention analysis for streaming stop/rewind decisions |
| `utils.zig` | Pure utility functions (word counting, PCM conversion, delta tracking) |
| `vad.zig` | Silero VAD wrapper for speech/silence detection |
| `audio_capture.zig` | PipeWire audio capture via `pw_thread_loop` + `pw_stream` |
| `pw_detect.zig` | PipeWire device enumeration and interactive channel detection |
| `pw_helpers.c` | C helpers for PipeWire SPA pod building and source enumeration |

## Server options

```
zigsper [OPTIONS]

  --model, -m PATH        Whisper model path (default: whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin)
  --vad-model PATH        VAD model path (default: whisper.cpp/models/ggml-silero-v5.1.2.bin)
  --port, -p PORT         TCP port (default: 43007, use 0 for OS-assigned)
  --warmup-file PATH      WAV file for GPU warmup (default: jfk.wav)
  --no-warmup             Skip warmup inference
  --input tcp|local       Input mode: tcp (socket) or local (PipeWire capture)
  --trigger KEY           Trigger key for push-to-talk (default: capslock)
  --trigger-passthrough   Forward trigger key to OS after interception
  --type-delay MS         Delay between injected keystrokes in ms (default: 12)
  --pw-target NODE        PipeWire capture target node name
  --pw-channel CHANNEL    PipeWire channel: MONO, FL, AUX0-AUX63 (default: FL)
  --pw-list               List available PipeWire audio sources
  --pw-detect             Interactive channel detection (record silence + speech)
  --detect-duration SECS  Duration per detection phase (default: 5)
  --verbose               Enable verbose logging
```

## Building & testing

All commands go through the Bun-based task runner (`run.ts`), which bootstraps its own toolchain via `bootstrap.sh` + mise.

```bash
# Build (default command)
./run.ts build

# Rebuild whisper.cpp shared libs (only needed after bumping submodule)
./run.ts rebuild-whisper

# Unit + property tests (no GPU required)
./run.ts test

# All integration tests (requires GPU + built binary)
./run.ts slow-test

# Individual integration tests
./run.ts slow-test stream         # TCP stream jfk.wav
./run.ts slow-test pw-stream      # PipeWire loopback test
./run.ts slow-test compare        # Compare against reference transcript
./run.ts slow-test long-stream    # jfk.wav × 20 loops (~3.7 min)
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ZIGSPER_PW_CHANNEL` | `FL` | PipeWire channel to capture |
| `ZIGSPER_PW_TARGET` | *(unset)* | PipeWire node to capture from |

## Performance

On an RTX 5070 Ti with the `large-v3-turbo-q5_0` model:

- Model load: ~1.2s
- Encode: ~85ms per chunk
- Streaming latency: ~1s between word emissions
- First transcription: ~1.4s total

## Troubleshooting

**Server fails to start** — check `/tmp/zigsper.log`. Ensure CUDA is installed and GPU has sufficient VRAM.

**"Failed to load model"** — model file not found. Download it:
```bash
cd whisper.cpp/models && ./download-ggml-model.sh large-v3-turbo-q5_0
```

**Cannot open /dev/input** — ensure your user is in the `input` group (`groups` to check, `sudo usermod -aG input $USER` then log out/in).

**Text not being typed** — ensure `/dev/uinput` is accessible. The udev rule should be set up by `./run setup`, or manually: `echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules && sudo udevadm control --reload-rules && sudo udevadm trigger /dev/uinput`.

**Keyboard locked up** — press Enter+Backspace+Escape simultaneously to trigger the panic sequence and ungrab all keyboards.

**Build fails** — ensure the whisper.cpp submodule is initialised and Git LFS files are pulled:
```bash
git submodule update --init --recursive
git lfs pull
```

**PipeWire capture fails** — ensure PipeWire is running (`pw-cli info`). Use `zigsper --pw-list` to see available sources, and `zigsper --pw-detect` to find the correct channel for multi-channel devices.

**Quiet or degraded transcription** — if using a multi-channel audio interface (e.g. Focusrite Vocaster), make sure you're capturing the correct channel (not a MONO downmix). Run `zigsper --pw-detect` and set `--pw-channel` accordingly.
