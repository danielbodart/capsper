# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires an NVIDIA GPU with CUDA. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
# Build (checks deps, inits submodule, runs CMake + Zig compilation)
./run.ts

# Clean build artifacts
./run.ts clean

# Run the server directly (loads model + VAD, warms up, listens on TCP)
./zig-out/bin/whisper-dictate --port 43007

# Run the full dictation system (server + key monitoring + audio piping)
./whisper.sh

# First-time setup (builds, installs systemd service, Wayland keyd/ydotoold)
./run.ts setup
```

### Testing

```bash
# Short integration test: stream jfk.wav (~11s) at real-time rate
./run.ts test-stream jfk.wav

# Long integration test: loop jfk.wav 20x (~3.7 min) to verify sliding window stability
./run.ts test-long-stream

# Comparison test: stream long-recording.wav, compare against batch transcript (~1m42s)
./run.ts test-compare

# PipeWire integration test
./run.ts test-pw-stream jfk.wav
```

Unit tests and property tests run automatically as part of `./run.ts` (via `zig build`). Unit tests live inline in `src/utils.zig` and `src/alignatt.zig` (pure Zig modules with no C deps). Property-based tests in `src/prop_tests.zig` use [minish](https://github.com/CogitatorTech/minish) for fuzz-like coverage of word-level delta/stability functions. Integration tests are self-contained: each starts its own server with `--port 0` (OS-assigned port), parses the port from the "Listening on port" log line, and cleans up on exit.

**When writing new code, add unit tests for any pure functions** (functions that don't depend on whisper.cpp C types). Keep testable logic in modules that don't import `whisper_c.zig` so tests run fast without requiring the GPU or model.

**For functions with tricky invariants** (word matching, offset calculations, stability/delta logic), add property-based tests in `src/prop_tests.zig` using minish. Good candidates: functions that are idempotent, symmetric, have roundtrip relationships, or where edge cases around spaces/punctuation/empty strings matter. Property tests catch bugs that hand-written examples miss.

## Architecture

Push-to-talk voice dictation for Linux. Audio flows: microphone -> `arecord | nc` -> Zig TCP server -> transcribed text -> `xdotool type` into focused window.

### Zig Server (`src/`)

The Zig binary replaces a Python SimulStreaming server. It links whisper.cpp as shared libraries built via CMake.

- **`main.zig`** — Entry point. Loads whisper model + VAD model, runs warmup inference on `jfk.wav`, starts TCP server.
- **`server.zig`** — TCP server with streaming state machine (`idle` -> `speaking` -> `trailing_silence`). Accepts raw S16_LE PCM over socket. Uses VAD to detect speech boundaries. Runs transcription on accumulated audio buffer, emits word-level deltas with stability checking (word must appear in 2 consecutive cycles before being emitted). Wire protocol: `{elapsed}.{tenths}\t{text}\n`.
- **`pipeline.zig`** — Low-level whisper.cpp integration. Manually drives mel spectrogram, encode, and autoregressive decode loop (no `whisper_full`). Implements AlignAtt streaming policy via cross-attention analysis to decide when to stop decoding.
- **`alignatt.zig`** — AlignAtt attention analysis: z-score normalization, median filtering, head averaging, stopping/rewind detection.
- **`utils.zig`** — Pure utility functions (no C deps): word counting, byte offsets, word-level delta/stability tracking, PCM-to-float conversion, buffer trimming. Independently unit-tested.
- **`vad.zig`** — Thin wrapper around whisper.cpp's Silero VAD.
- **`whisper_c.zig`** — C import bridge. Re-exports whisper.cpp types/functions for use in Zig code.

### Scripts & Task Runner

- **`run.ts`** — Bun task runner (bootstrapped via `bootstrap.sh` + mise). Commands: `build`, `clean`, `setup`, `test-stream`, `test-pw-stream`, `test-long-stream`, `test-compare`.
- **`whisper.sh`** — Main user-facing script. Starts the Zig server, monitors F24 key (xinput on X11, evtest on Wayland), pipes audio to server, types transcribed text via xdotool/ydotool.

### Build System

`build.zig` drives a two-stage build:
1. CMake builds whisper.cpp as **shared libraries** (with CUDA, flash attention) into `whisper.cpp/build-zig/`
2. Zig compiles the server binary, linking those shared libs with RPaths set for runtime discovery

Static linking is intentionally avoided — Zig's bundled libc++ conflicts with whisper.cpp's libstdc++ dependency.

## Key Technical Details

- **30-second padding**: whisper.cpp's mel computation requires 480000 samples (30s). Short audio must be zero-padded or the decoder emits immediate EOT.
- **Split prompt decode**: `whisper_get_logits_from_state()` reads from offset 0, but batch decode only populates logits for the last token. Prompt tokens are decoded in two calls: batch first N-1, then the last token alone.
- **AlignAtt always `is_last=true`**: The frame_threshold=25 is too conservative for short streaming buffers. Server-side word stability checking handles hallucination filtering instead.
- **Word-level delta tracking**: Stability is checked at word granularity (not byte), using case-insensitive comparison with trailing punctuation stripped. This handles Whisper changing "so" to "so," between cycles.
- **Sliding window**: Audio buffer capped at 15s (`max_buffer_bytes=480000`). When trimmed, prev_text offset scanning (up to 6 words) realigns the emitted word count.
- **PipeWire FFI must go through C helpers**: Passing `spa_pod**` params through Zig FFI breaks SPA format negotiation (ports get generic names like `input_1`, auto-connect fails, resampling doesn't happen). All PipeWire calls involving SPA pods or variadic macros must be in `src/pw_helpers.c`, not called directly from Zig.

## Workflow

**Always run tests before fixing bugs.** Reproduce the issue first with a test, verify the fix with the same test. Use `./run.ts test-compare` to get a baseline before and after changes — it gives concrete word coverage numbers to measure improvement.

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- whisper.cpp is a git submodule pinned to commit `0a4d85cf`
- Model: `ggml-large-v3-turbo-q5_0.bin` (573 MB, q5_0 quantization)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default server port: 43007
- User is on X11 (not Wayland)
