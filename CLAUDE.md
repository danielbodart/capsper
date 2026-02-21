# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires an NVIDIA GPU with CUDA. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
# Default: build + unit tests + short regressions + pw plumbing
./run.ts

# Build only (no tests)
./run.ts build

# Clean build artifacts
./run.ts clean

# Run directly (loads model, grabs keyboard, CapsLock = push-to-talk)
./dist/bin/capsper --trigger capslock --pw-channel FL

# First-time setup (builds, configures evdev permissions, installs systemd service)
./run.ts setup
```

### Testing

```bash
# Unit + property tests (fast, no GPU required)
./run.ts test

# Regression test groups (requires GPU + built binary)
./run.ts short-test                    # 4 short files (<15s) via fast TCP
./run.ts medium-test                   # 2 medium files (15-40s) via fast TCP
./run.ts long-test                     # 3 long files (>60s) via fast TCP

# All integration tests (all groups + stability + pw plumbing)
./run.ts slow-test
```

## Architecture

Push-to-talk voice dictation for Linux. Self-contained binary: grabs keyboards via evdev, intercepts CapsLock as trigger, captures audio via PipeWire, transcribes with whisper.cpp, injects text as keystrokes via uinput. No external tools needed (no xdotool, ydotool, keyd, xinput). Works on both X11 and Wayland.

### Zig Binary (`src/`)

Single binary handles everything: keyboard grab, audio capture, transcription, text injection.

- **`main.zig`** — Entry point. Loads whisper + VAD models, warmup, wires input handler to server.
- **`server.zig`** — Streaming state machine (`idle` -> `speaking` -> `trailing_silence`). Accepts PCM from PipeWire (local mode) or TCP socket. Uses VAD for speech boundaries. Emits word-level deltas. Supports `TypeCallback` for uinput text injection.
- **`input.zig`** — evdev/uinput input handling. Grabs physical keyboards, forwards all keys through virtual uinput keyboard, intercepts trigger key for push-to-talk, injects transcribed text as keystrokes. Includes hotplug (inotify) and panic sequence (Enter+Backspace+Escape = ungrab).
- **`pipeline.zig`** — Low-level whisper.cpp integration. Manually drives mel spectrogram, encode, and autoregressive decode loop (no `whisper_full`). Implements AlignAtt streaming policy via cross-attention analysis to decide when to stop decoding. Supports domain term prompting via `<|startofprev|>` token prefix.
- **`alignatt.zig`** — AlignAtt attention analysis: z-score normalization, median filtering, head averaging, stopping/rewind detection.
- **`utils.zig`** — Pure utility functions (no C deps): PCM-to-float conversion, buffer trimming, WAV parsing/writing, per-channel RMS analysis, text preview. Independently unit-tested.
- **`audio_capture.zig`** — PipeWire audio capture via `pw_thread_loop` + `pw_stream`.
- **`pw_detect.zig`** — PipeWire device enumeration (`--pw-list`) and interactive channel detection (`--pw-detect`). Records silence/speech, compares per-channel RMS to recommend the best `--pw-channel`.
- **`vad.zig`** — Thin wrapper around whisper.cpp's Silero VAD.
- **`whisper_c.zig`** / **`pipewire_c.zig`** — C import bridges for whisper.cpp and PipeWire.
- **`pw_helpers.c`** — C helpers for PipeWire SPA pod building, `pw_stream_connect`, and PipeWire source enumeration (variadic C calls and SPA macros that Zig can't handle).

### Scripts & Task Runner

- **`run.ts`** — Bun task runner (bootstrapped via `bootstrap.sh` + mise). Commands: `dev` (default), `build`, `clean`, `setup`, `test`, `slow-test`, `rebuild-whisper`, `dist`, `ci`.
- **`install.sh`** — Self-contained bash installer. Ships in dist tarball. Subcommands: `install` (default), `pw-detect`. Auto-detects dev mode (git checkout via `../.git`) vs user install (`~/.local/share/capsper/`).

### Build System & `dist/` Layout

Pre-built whisper.cpp shared libraries are committed in `dist/lib/` via Git LFS (~43 MB). The Zig build links against these directly — no CMake step needed for normal builds.

```
dist/
├── bin/capsper              (built by zig — gitignored)
├── lib/                     (pre-built .so files — committed via LFS)
│   ├── libwhisper.so.1.8.3, libwhisper.so.1, libwhisper.so
│   ├── libggml-cuda.so.0.9.6, libggml-cuda.so.0, libggml-cuda.so
│   └── (libggml, libggml-base, libggml-cpu — same pattern)
└── install.sh               (committed)
```

## Deployment

To update the running capsper service after CI passes:

```bash
~/.local/share/capsper/capsper-update.sh    # downloads from GitHub Releases, stages, verifies SHA256
systemctl --user restart capsper             # apply-update.sh runs as ExecStartPre, swaps symlink
```

Do NOT manually download CI artifacts or stage releases by hand — the update script handles everything.

## Worktrees

Worktrees live in `.worktrees/` (gitignored). When creating a new worktree:

1. Create the worktree: `git worktree add .worktrees/<name> -b feature/<name>`
2. Symlink models (they're gitignored and large — don't re-download):
   ```bash
   ln -s $PWD/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin .worktrees/<name>/whisper.cpp/models/
   ln -s $PWD/whisper.cpp/models/ggml-silero-v5.1.2.bin .worktrees/<name>/whisper.cpp/models/
   ```
3. Build and verify: `cd .worktrees/<name> && ./run.ts`

## Workflow

**Always run tests before fixing bugs.** Reproduce the issue first with a test, verify the fix with the same test. Run `./run.ts slow-test` before and after changes — the scorecard shows Coverage, WER (Word Error Rate), and per-error-type breakdown (Subs/Ins/Del) to measure improvement.

## Reference Codebases

When unsure about implementation approach, always check these codebases for inspiration in this order:

1. **SimulStreaming** (`/home/dan/Projects/SimulStreaming/`) — the Python streaming transcription system capsper's architecture is ported from. The VAC (Voice Activity Controller) online processor, AlignAtt policy, and streaming decode loop are the reference implementations. Check here first for architectural questions.
2. **whisper.cpp** (`whisper.cpp/` submodule) — the C library capsper links against. Check here for API usage, mel computation, VAD internals, and understanding what the model expects.

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- whisper.cpp is a git submodule pinned to commit `0a4d85cf`
- Model: `ggml-large-v3-turbo-q5_0.bin` (573 MB, q5_0 quantization)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default server port: 43007
