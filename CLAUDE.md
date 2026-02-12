# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires **Zig 0.15.2** (installed via mise) and an NVIDIA GPU with CUDA.

```bash
# Build (runs CMake for whisper.cpp shared libs, then compiles Zig binary)
mise exec zig -- zig build

# Run the server directly (loads model + VAD, warms up, listens on TCP)
./zig-out/bin/whisper-dictate --port 43007

# Run the full dictation system (server + key monitoring + audio piping)
./whisper.sh

# First-time setup (installs system deps, builds, creates systemd service)
./run.sh
```

### Testing

```bash
# Unit tests + property tests (pure Zig, no GPU/model required)
mise exec zig -- zig build test

# Property tests only (minish, 500 random inputs × 27 properties)
mise exec zig -- zig build prop-test

# Short integration test: stream jfk.wav (~11s) at real-time rate
./test-stream.sh jfk.wav 43007

# Long integration test: loop jfk.wav 20x (~3.7 min) to verify sliding window stability
./test-long-stream.sh 43007
```

Unit tests live inline in `src/utils.zig` and `src/alignatt.zig` (pure Zig modules with no C deps). Property-based tests in `src/prop_tests.zig` use [minish](https://github.com/CogitatorTech/minish) for fuzz-like coverage of word-level delta/stability functions. Integration tests use `pv -qL 32000` to rate-limit raw PCM to 16kHz S16 mono and require a running server.

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

### Shell Scripts

- **`whisper.sh`** — Main user-facing script. Starts the Zig server, monitors F24 key (xinput on X11, evtest on Wayland), pipes audio to server, types transcribed text via xdotool/ydotool.
- **`run.sh`** — One-time setup: builds binary, installs system deps, creates systemd user service.

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

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- whisper.cpp is a git submodule pinned to commit `0a4d85cf`
- Model: `ggml-large-v3-turbo-q5_0.bin` (573 MB, q5_0 quantization)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default server port: 43007
- User is on X11 (not Wayland)
