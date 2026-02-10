# Whisper Dictation

Push-to-talk voice dictation for Linux. Hold a key, speak, and text is typed into whatever window is focused.

Uses [SimulStreaming](https://github.com/ufal/SimulStreaming) for real-time streaming speech recognition with OpenAI's Whisper `large-v3-turbo` model running locally on GPU.

## How it works

1. A local SimulStreaming server runs the Whisper model and listens on a TCP socket
2. Microphone audio is streamed to the server via `arecord | nc`
3. The server returns transcribed text as it's recognised
4. Text is typed into the focused window when the push-to-talk key (F24) is held

## Requirements

- Linux (Debian/Ubuntu)
- NVIDIA GPU with ~4 GB VRAM (for `large-v3-turbo`)
- [mise](https://mise.jdx.dev) (manages the Python install)
- An F24 key — either hardware-mapped (e.g. a programmable keyboard) or software-mapped via keyd (set up automatically on Wayland)

## Setup

```bash
git clone --recurse-submodules https://github.com/danielbodart/whisper.git
cd whisper
./run.sh
```

`run.sh` handles everything:

- Initialises the SimulStreaming git submodule
- Installs Python 3.12 via mise
- Installs Python dependencies (PyTorch, librosa, etc.)
- Installs system packages via `sudo apt install` (will prompt for password)
- Downloads the Whisper `large-v3-turbo` model (~1.5 GB)
- On Wayland: configures keyd to remap Caps Lock to F24 and sets up uinput permissions

## Usage

```bash
./whisper.sh
```

Hold F24 (or Caps Lock if keyd is configured) and speak. Release to stop. Text appears in the focused window.

## Display server support

The script auto-detects Wayland vs X11 and uses the appropriate tools:

| | Wayland | X11 |
|---|---|---|
| **Key monitoring** | evtest | xinput |
| **Text typing** | ydotool | xdotool |
| **Key remapping** | keyd (Caps Lock to F24) | Hardware or xmodmap |
| **Keyboard detection** | Auto (via /proc/bus/input/devices) | Manual device ID |

Override auto-detection with:

```bash
WHISPER_BACKEND=x11 ./whisper.sh
WHISPER_BACKEND=wayland ./whisper.sh
```

On X11, set the keyboard device ID if the default doesn't match:

```bash
WHISPER_KEYBOARD_ID=15 ./whisper.sh
```

## Scripts

| Script | Purpose |
|---|---|
| `run.sh` | One-time setup — installs everything |
| `whisper.sh` | Starts the server and dictation |
| `setup-keyd.sh` | Configures keyd + uinput (run by `run.sh` on Wayland, or manually with `sudo`) |

## SimulStreaming

The speech recognition is powered by [SimulStreaming](https://github.com/ufal/SimulStreaming) from Charles University (UFAL). It implements the AlignAtt simultaneous speech processing policy with Whisper, providing low-latency streaming transcription — significantly faster than the earlier [whisper_streaming](https://github.com/ufal/whisper_streaming) project it replaces.

The SimulStreaming server runs Whisper locally on GPU with Voice Activity Detection (Silero VAD), streaming transcription results over a TCP socket as audio arrives.

## Troubleshooting

**Server fails to start** — check `/tmp/whisper-dictation.log` for errors. Ensure you have a CUDA-capable GPU and sufficient VRAM.

**No key events detected on Wayland** — ensure your user is in the `input` group (`groups` to check, `sudo usermod -aG input $USER` then log out/in to fix).

**ydotool fails to type** — ensure `/dev/uinput` is accessible (`ls -la /dev/uinput` should show group `input` with `rw` permissions). Run `sudo ./setup-keyd.sh` to fix.

**Wrong keyboard detected** — the script prefers the keyd virtual keyboard if keyd is running, otherwise picks the first physical keyboard. Check `cat /proc/bus/input/devices` to see available devices.
