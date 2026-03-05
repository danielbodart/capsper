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
./dist/bin/capsper --trigger capslock --pw-channel FL --drop-terms drop-terms.txt

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
- **`server.zig`** — Streaming 2-state machine (`idle` → `speaking`). Accepts PCM from PipeWire (local mode) or TCP socket. VadFilter edge detection drives state transitions. `speech_buf` only contains speech audio (never silence). Emits word-level deltas. Supports `TypeCallback` for uinput text injection.
- **`input.zig`** — evdev/uinput input handling. Grabs physical keyboards, forwards all keys through virtual uinput keyboard, intercepts trigger key for push-to-talk, injects transcribed text as keystrokes. Includes hotplug (inotify), panic sequence (Enter+Backspace+Escape = ungrab), EVIOCGKEY polling safety net (catches lost key release events every 200ms), and typing cancel (interrupts text injection on PTT release).
- **`pipeline.zig`** — Low-level whisper.cpp integration. Manually drives mel spectrogram, encode, and autoregressive decode loop (no `whisper_full`). Implements AlignAtt streaming policy via cross-attention analysis for stopping and rewind detection. Two-tier token system: forced tokens (after `[notimestamps]`) for audio in buffer, context tokens (before `[sot]`) for trimmed audio. Supports domain term prompting via `<|startofprev|>` token prefix.
- **`alignatt.zig`** — AlignAtt attention analysis: z-score normalization, median filtering, head averaging, stopping/rewind detection.
- **`utils.zig`** — Pure utility functions (no C deps): PCM-to-float conversion, buffer trimming, WAV parsing/writing, per-channel RMS analysis, text preview. Independently unit-tested.
- **`audio_capture.zig`** — PipeWire audio capture via `pw_thread_loop` + `pw_stream`. Supports software gain via `setGain()`.
- **`pw_detect.zig`** — Interactive PipeWire setup wizard (`--pw-detect`). Enumerates devices, lets user pick, records silence/speech, detects best channel, calibrates auto-gain — all in one flow. Outputs `CHANNEL=`/`GAIN=` to stdout for `install.sh`.
- **`auto_gain.zig`** — Pure-math auto-gain controller. Measures speech RMS and computes PipeWire software gain to reach target level. Capped at 10x (PipeWire ceiling). Used at runtime by `server.zig` and for calibration by `pw_detect.zig`.
- **`vad.zig`** — Multi-backend VAD with state machine. Supports TEN-VAD GGML (default, `--vad ten`) and Silero (`--vad silero`, via whisper.cpp). Each backend has tuned default thresholds. `VadFilter` is the backend-agnostic state machine; `VadBackend` is the tagged union dispatch.
- **`whisper_c.zig`** / **`pipewire_c.zig`** — C import bridges for whisper.cpp and PipeWire.
- **`pw_helpers.c`** — C helpers for PipeWire SPA pod building, `pw_stream_connect`, `pw_set_stream_gain`, and PipeWire source enumeration (variadic C calls and SPA macros that Zig can't handle).

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
├── models/
│   ├── ten-vad-ggml.bin             (296 KB, committed via LFS)
│   ├── ggml-silero-v5.1.2.bin       (865 KB, committed)
│   └── ggml-large-v3-turbo-q5_0.bin (574 MB, gitignored — downloaded on first run)
└── install.sh               (committed)
```

## Deployment

To update the running capsper service after CI passes:

```bash
~/.local/share/capsper/capsper-update.sh    # downloads from GitHub Releases, stages, verifies SHA256
systemctl --user restart capsper             # apply-update.sh runs as ExecStartPre, swaps symlink
```

Do NOT manually download CI artifacts or stage releases by hand — the update script handles everything.

## Workflow

**Always run tests before fixing bugs.** Reproduce the issue first with a test, verify the fix with the same test.

**Don't run redundant test commands.** `./run.ts` (no args) already does build + unit tests + property tests + short regressions + PipeWire plumbing — that's the standard verify step. Do NOT run `./run.ts build`, `./run.ts test`, and `./run.ts short-test` separately — that just repeats work. Only run `./run.ts slow-test` when you specifically need medium/long regression results (e.g. measuring WER improvement on long files).

## Rules

**Never change test thresholds without human approval.** Regression test thresholds (coverage, WER, gap, repetition limits) in `.test.json` files are carefully tuned. If a code change causes tests to fail, fix the code — don't relax the thresholds. If thresholds genuinely need updating, present the before/after results and get explicit human sign-off.

**Do not attribute test result differences to CUDA non-determinism.** When results differ between test modes or runs, the cause is almost always a real discrepancy in the test methodology or a real code bug — not GPU randomness. Investigate the actual root cause instead of dismissing differences as non-determinism.

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- whisper.cpp is a git submodule pinned to commit `0a4d85cf`
- ten-vad is a git submodule pinned to commit `22a3bcd` (TEN-framework/ten-vad, ONNX model source for GGML converter)
- Model: `ggml-large-v3-turbo-q5_0.bin` (573 MB, q5_0 quantization)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default server port: 43007
