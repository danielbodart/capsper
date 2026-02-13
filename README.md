# Whisper Dictation

Push-to-talk voice dictation for Linux. Hold a key, speak, release — text is typed into whatever window is focused.

Uses a custom streaming speech recognition server written in Zig, linking [whisper.cpp](https://github.com/ggml-org/whisper.cpp) for local GPU inference with the `large-v3-turbo` model. Implements [AlignAtt](https://aclanthology.org/2023.findings-emnlp.744/) simultaneous speech processing for low-latency streaming transcription with word-level stability checking.

## How it works

1. The Zig server loads the Whisper model and captures audio directly via PipeWire
2. The server runs incremental transcription with VAD (Silero) and emits stable words as they're recognised
3. `xdotool` (X11) or `ydotool` (Wayland) types the text into the focused window
4. A shell script monitors the push-to-talk key (F24) to gate audio capture

## Requirements

- Linux (Debian/Ubuntu)
- NVIDIA GPU with ~4 GB VRAM
- CUDA toolkit
- PipeWire (default audio server on modern Ubuntu/Fedora)
- [mise](https://mise.jdx.dev) — installs Zig 0.15.2 and Bun automatically via `bootstrap.sh`
- An F24 key — either hardware-mapped (e.g. a programmable keyboard) or software-mapped via keyd (set up automatically on Wayland)

## Setup

```bash
# Clone with submodules (whisper.cpp)
git clone --recurse-submodules https://github.com/danielbodart/whisper.git
cd whisper

# Download the models (~574 MB total)
cd whisper.cpp/models
./download-ggml-model.sh large-v3-turbo-q5_0
./download-vad-model.sh silero-v5.1.2
cd ../..

# Build the Zig binary (installs mise/bun/zig on first run, builds whisper.cpp via CMake)
./run.ts build

# Install system dependencies + create systemd service
./run.ts setup
```

`./run.ts setup` handles:
- Installing system packages (`xinput`/`xdotool` or `evtest`/`ydotool`, `pv`, `ncat`)
- On Wayland: configuring keyd (Caps Lock to F24) and uinput permissions
- Creating a systemd user service for background operation

## Usage

```bash
# Start dictation directly
./whisper.sh

# Or via systemd (after setup)
systemctl --user start whisper
```

Hold F24 (or Caps Lock if keyd is configured) and speak. Release to stop. Text appears in the focused window.

### PipeWire channel selection

For multi-channel audio interfaces, use `pw-detect` to find which channel carries your microphone signal:

```bash
./run.ts pw-detect
```

This records silence and speech, then shows per-channel signal levels and recommends the correct `--pw-channel` flag. Set it via environment variable:

```bash
WHISPER_PW_CHANNEL=AUX2 ./whisper.sh
```

## Architecture

```
Microphone → [PipeWire] → [Zig Server] → transcribed text → xdotool/ydotool → focused window
                               ↓
                       whisper.cpp (GPU)
                       Silero VAD
                       AlignAtt streaming
                       Word-level stability
```

The Zig server (`src/`) handles the heavy lifting:

| File | Purpose |
|---|---|
| `main.zig` | Entry point, argument parsing, model loading, warmup |
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
  --input tcp|local       Input mode: tcp (socket) or local (PipeWire capture, default in whisper.sh)
  --pw-target NODE        PipeWire capture target node name
  --pw-channel CHANNEL    PipeWire channel: MONO, FL, AUX0-AUX7 (default: AUX2)
```

## Display server support

Auto-detects Wayland vs X11 and uses the appropriate tools:

| | Wayland | X11 |
|---|---|---|
| **Key monitoring** | evtest | xinput |
| **Text typing** | ydotool | xdotool |
| **Key remapping** | keyd (Caps Lock to F24) | Hardware or xmodmap |
| **Keyboard detection** | Auto (via /proc/bus/input/devices) | Auto (via xinput + /proc/bus/input/devices) |

Override auto-detection:

```bash
WHISPER_BACKEND=x11 ./whisper.sh
WHISPER_BACKEND=wayland ./whisper.sh
```

## Building & testing

All commands go through the Bun-based task runner (`run.ts`), which bootstraps its own toolchain via `bootstrap.sh` + mise.

```bash
# Build (default command)
./run.ts build

# Force rebuild including whisper.cpp CMake + CUDA
./run.ts rebuild

# Unit + property tests (no GPU required)
mise exec zig -- zig build test

# Stream jfk.wav at real-time rate via TCP
./run.ts test-stream jfk.wav

# Stream via PipeWire loopback (tests full PipeWire path)
./run.ts test-pw-stream jfk.wav

# Long-running stability test (jfk.wav × 20 loops, ~3.7 min)
./run.ts test-long-stream

# Compare streaming output against reference transcript
./run.ts test-compare

# Detect best PipeWire channel for your microphone
./run.ts pw-detect
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `WHISPER_PW_CHANNEL` | `AUX2` | PipeWire channel to capture |
| `WHISPER_PW_TARGET` | *(unset)* | PipeWire node to capture from |
| `WHISPER_BACKEND` | *(auto)* | Force `x11` or `wayland` backend |
| `WHISPER_KEYBOARD_ID` | *(auto)* | X11 xinput device ID override |

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

**No key events detected on Wayland** — ensure your user is in the `input` group (`groups` to check, `sudo usermod -aG input $USER` then log out/in).

**ydotool fails to type** — ensure `/dev/uinput` is accessible. Run `sudo ./setup-keyd.sh` to fix permissions.

**Wrong keyboard detected** — check `cat /proc/bus/input/devices` to see available devices.

**Build fails with CMake errors** — ensure the whisper.cpp submodule is initialised:
```bash
git submodule update --init --recursive
```

**PipeWire capture fails** — ensure PipeWire is running (`pw-cli info`). For multi-channel devices, run `./run.ts pw-detect` to find the correct channel.

**Quiet or degraded transcription** — if using a multi-channel audio interface (e.g. Focusrite Vocaster), make sure you're capturing the correct channel (not a MONO downmix). Run `./run.ts pw-detect` and set `WHISPER_PW_CHANNEL` accordingly.
