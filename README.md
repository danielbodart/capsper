# Whisper Dictation

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
- CUDA toolkit
- PipeWire (default audio server on modern Ubuntu/Fedora)
- User in the `input` group (for evdev keyboard grab and uinput text injection)

## Setup

```bash
git clone --recurse-submodules https://github.com/danielbodart/whisper.git
cd whisper
./run
```

This auto-detects and handles everything:
- Installs toolchain (mise, Zig 0.15.2, Bun) on first run via `bootstrap.sh`
- Installs system packages (`pv`, `ncat`, `cmake`)
- Initialises the whisper.cpp submodule if needed
- Downloads models (~574 MB Whisper model + VAD model) if missing
- Builds whisper.cpp shared libs via CMake with CUDA
- Compiles the Zig binary
- Configures uinput permissions (for text injection via virtual keyboard)
- Creates and enables a systemd user service

Every step is incremental — re-running `./run` is fast if everything is already set up.

## Usage

```bash
systemctl --user start whisper.service
```

Hold CapsLock and speak. Release to stop. Text appears in the focused window.

### PipeWire channel selection

For multi-channel audio interfaces, use `pw-detect` to find which channel carries your microphone signal:

```bash
./run pw-detect
```

This records silence and speech, then shows per-channel signal levels and recommends the correct `--pw-channel` flag. Set it via environment variable:

```bash
WHISPER_PW_CHANNEL=AUX2 systemctl --user restart whisper.service
```

## Architecture

```
Physical Keyboard ──evdev──→ whisper-dictate ──uinput──→ Virtual Keyboard → Apps
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
| `pw_helpers.c` | C helpers for PipeWire SPA pod building (Zig FFI can't call variadic C macros) |

## Server options

```
whisper-dictate [OPTIONS]

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
  --pw-channel CHANNEL    PipeWire channel: MONO, FL, AUX0-AUX7 (default: AUX2)
  --verbose               Enable verbose logging
```

## Building & testing

All commands go through the Bun-based task runner (`run.ts`), which bootstraps its own toolchain via `bootstrap.sh` + mise.

```bash
# Build (default command)
./run build

# Force rebuild including whisper.cpp CMake + CUDA
./run rebuild

# Unit + property tests (no GPU required)
mise exec zig -- zig build test

# Stream jfk.wav at real-time rate via TCP
./run test-stream jfk.wav

# Stream via PipeWire loopback (tests full PipeWire path)
./run test-pw-stream jfk.wav

# Long-running stability test (jfk.wav × 20 loops, ~3.7 min)
./run test-long-stream

# Compare streaming output against reference transcript
./run test-compare

# Detect best PipeWire channel for your microphone
./run pw-detect
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `WHISPER_PW_CHANNEL` | `AUX2` | PipeWire channel to capture |
| `WHISPER_PW_TARGET` | *(unset)* | PipeWire node to capture from |

## Performance

On an RTX 5070 Ti with the `large-v3-turbo-q5_0` model:

- Model load: ~1.2s
- Encode: ~85ms per chunk
- Streaming latency: ~1s between word emissions
- First transcription: ~1.4s total

## Troubleshooting

**Server fails to start** — check `/tmp/whisper-dictation.log`. Ensure CUDA is installed and GPU has sufficient VRAM.

**"Failed to load model"** — model file not found. Download it:
```bash
cd whisper.cpp/models && ./download-ggml-model.sh large-v3-turbo-q5_0
```

**Cannot open /dev/input** — ensure your user is in the `input` group (`groups` to check, `sudo usermod -aG input $USER` then log out/in).

**Text not being typed** — ensure `/dev/uinput` is accessible. The udev rule should be set up by `./run setup`, or manually: `echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules && sudo udevadm control --reload-rules && sudo udevadm trigger /dev/uinput`.

**Keyboard locked up** — press Enter+Backspace+Escape simultaneously to trigger the panic sequence and ungrab all keyboards.

**Build fails with CMake errors** — ensure the whisper.cpp submodule is initialised:
```bash
git submodule update --init --recursive
```

**PipeWire capture fails** — ensure PipeWire is running (`pw-cli info`). For multi-channel devices, run `./run pw-detect` to find the correct channel.

**Quiet or degraded transcription** — if using a multi-channel audio interface (e.g. Focusrite Vocaster), make sure you're capturing the correct channel (not a MONO downmix). Run `./run pw-detect` and set `WHISPER_PW_CHANNEL` accordingly.
