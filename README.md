# Whisper Dictation

Push-to-talk voice dictation for Linux. Hold a key, speak, release — text is typed into whatever window is focused.

Uses a custom streaming speech recognition server written in Zig, linking [whisper.cpp](https://github.com/ggml-org/whisper.cpp) for local GPU inference with the `large-v3-turbo` model. Implements [AlignAtt](https://aclanthology.org/2023.findings-emnlp.744/) simultaneous speech processing for low-latency streaming transcription with word-level stability checking.

## How it works

1. A Zig TCP server loads the Whisper model and listens for raw audio
2. `arecord` captures microphone audio, piped to the server via `nc`
3. The server runs incremental transcription with VAD (Silero) and emits stable words as they're recognised
4. `xdotool` (X11) or `ydotool` (Wayland) types the text into the focused window
5. A shell script monitors the push-to-talk key (F24) to gate audio capture

## Requirements

- Linux (Debian/Ubuntu)
- NVIDIA GPU with ~4 GB VRAM
- CUDA toolkit
- [Zig 0.15.2](https://ziglang.org/) — install via [mise](https://mise.jdx.dev): `mise use zig@0.15`
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

# Build the Zig binary (also builds whisper.cpp shared libs via CMake)
mise exec zig -- zig build

# Install system dependencies + create systemd service
./run.sh
```

`run.sh` handles:
- Installing system packages (`alsa-utils`, `ncat`, `xinput`/`xdotool` or `evtest`/`ydotool`)
- On Wayland: configuring keyd (Caps Lock to F24) and uinput permissions
- Creating a systemd user service for background operation

## Usage

```bash
# Start dictation directly
./whisper.sh

# Or via systemd (after run.sh setup)
systemctl --user start whisper
```

Hold F24 (or Caps Lock if keyd is configured) and speak. Release to stop. Text appears in the focused window.

## Architecture

```
Microphone → arecord → nc → [Zig TCP Server] → transcribed text → xdotool/ydotool → focused window
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
| `server.zig` | TCP server, streaming state machine, word-level delta emission |
| `pipeline.zig` | Low-level whisper.cpp integration, mel/encode/decode loop |
| `alignatt.zig` | Cross-attention analysis for streaming stop/rewind decisions |
| `utils.zig` | Pure utility functions (word counting, PCM conversion, delta tracking) |
| `vad.zig` | Silero VAD wrapper for speech/silence detection |

## Server options

```
whisper-dictate [OPTIONS]

  --model, -m PATH      Whisper model path (default: whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin)
  --vad-model PATH      VAD model path (default: whisper.cpp/models/ggml-silero-v5.1.2.bin)
  --port, -p PORT       TCP port (default: 43007)
  --warmup-file PATH    WAV file for GPU warmup (default: jfk.wav)
  --no-warmup           Skip warmup inference
```

## Display server support

Auto-detects Wayland vs X11 and uses the appropriate tools:

| | Wayland | X11 |
|---|---|---|
| **Key monitoring** | evtest | xinput |
| **Text typing** | ydotool | xdotool |
| **Key remapping** | keyd (Caps Lock to F24) | Hardware or xmodmap |
| **Keyboard detection** | Auto (via /proc/bus/input/devices) | Manual device ID |

Override auto-detection:

```bash
WHISPER_BACKEND=x11 ./whisper.sh
WHISPER_BACKEND=wayland ./whisper.sh
```

On X11, set the keyboard device ID if the default doesn't match:

```bash
WHISPER_KEYBOARD_ID=15 ./whisper.sh
```

## Building & testing

```bash
# Build
mise exec zig -- zig build

# Unit + property tests (no GPU required)
mise exec zig -- zig build test

# Stream test audio at real-time rate (requires running server)
./test-stream.sh jfk.wav 43007
```

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
