# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires an NVIDIA GPU with CUDA. Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
# Default: build + unit tests + quick integration smoke tests (stream + pw-stream)
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

# All integration tests (requires GPU + built binary)
./run.ts slow-test

# Individual integration tests
./run.ts slow-test stream              # TCP stream jfk.wav (~11s)
./run.ts slow-test stream custom.wav   # TCP stream custom file
./run.ts slow-test long-stream         # Loop jfk.wav 20x (~3.7 min)
./run.ts slow-test compare             # Compare against reference transcript
./run.ts slow-test compare dictation   # Compare with testdata/dictation.wav
./run.ts slow-test pw-stream           # PipeWire loopback test
```

Unit tests and property tests run automatically as part of `./run.ts` (via `zig build`). Unit tests live inline in `src/utils.zig` and `src/alignatt.zig` (pure Zig modules with no C deps). Property-based tests in `src/prop_tests.zig` use [minish](https://github.com/CogitatorTech/minish) for fuzz-like coverage of word-level delta/stability functions. Integration tests are self-contained: each starts its own server with `--port 0` (OS-assigned port), parses the port from the "Listening on port" log line, and cleans up on exit.

**When writing new code, add unit tests for any pure functions** (functions that don't depend on whisper.cpp C types). Keep testable logic in modules that don't import `whisper_c.zig` so tests run fast without requiring the GPU or model.

**For functions with tricky invariants** (word matching, offset calculations, stability/delta logic), add property-based tests in `src/prop_tests.zig` using minish. Good candidates: functions that are idempotent, symmetric, have roundtrip relationships, or where edge cases around spaces/punctuation/empty strings matter. Property tests catch bugs that hand-written examples miss.

## Architecture

Push-to-talk voice dictation for Linux. Self-contained binary: grabs keyboards via evdev, intercepts CapsLock as trigger, captures audio via PipeWire, transcribes with whisper.cpp, injects text as keystrokes via uinput. No external tools needed (no xdotool, ydotool, keyd, xinput). Works on both X11 and Wayland.

### Zig Binary (`src/`)

Single binary handles everything: keyboard grab, audio capture, transcription, text injection.

- **`main.zig`** — Entry point. Loads whisper + VAD models, warmup, wires input handler to server.
- **`server.zig`** — Streaming state machine (`idle` -> `speaking` -> `trailing_silence`). Accepts PCM from PipeWire (local mode) or TCP socket. Uses VAD for speech boundaries. Emits word-level deltas with stability checking. Supports `TypeCallback` for uinput text injection.
- **`input.zig`** — evdev/uinput input handling. Grabs physical keyboards, forwards all keys through virtual uinput keyboard, intercepts trigger key for push-to-talk, injects transcribed text as keystrokes. Includes hotplug (inotify) and panic sequence (Enter+Backspace+Escape = ungrab).
- **`pipeline.zig`** — Low-level whisper.cpp integration. Manually drives mel spectrogram, encode, and autoregressive decode loop (no `whisper_full`). Implements AlignAtt streaming policy via cross-attention analysis to decide when to stop decoding.
- **`alignatt.zig`** — AlignAtt attention analysis: z-score normalization, median filtering, head averaging, stopping/rewind detection.
- **`utils.zig`** — Pure utility functions (no C deps): word counting, byte offsets, word-level delta/stability tracking, PCM-to-float conversion, buffer trimming, per-channel RMS analysis. Independently unit-tested.
- **`audio_capture.zig`** — PipeWire audio capture via `pw_thread_loop` + `pw_stream`.
- **`pw_detect.zig`** — PipeWire device enumeration (`--pw-list`) and interactive channel detection (`--pw-detect`). Records silence/speech, compares per-channel RMS to recommend the best `--pw-channel`.
- **`vad.zig`** — Thin wrapper around whisper.cpp's Silero VAD.
- **`whisper_c.zig`** / **`pipewire_c.zig`** — C import bridges for whisper.cpp and PipeWire.
- **`pw_helpers.c`** — C helpers for PipeWire SPA pod building, `pw_stream_connect`, and PipeWire source enumeration (variadic C calls and SPA macros that Zig can't handle).

### Scripts & Task Runner

- **`run.ts`** — Bun task runner (bootstrapped via `bootstrap.sh` + mise). Commands: `dev` (default), `build`, `clean`, `setup`, `test`, `slow-test`, `rebuild-whisper`, `dist`, `ci`.
- **`install.sh`** — Self-contained bash installer. Ships in dist tarball. Subcommands: `install` (default), `pw-detect`, `setup-dev` (called by `run.ts setup`).

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

- `zig build --prefix dist` — builds binary to `dist/bin/`, links libs from `dist/lib/`
- `zig build rebuild-libs --prefix dist` — rebuilds whisper.cpp shared libs via CMake (only needed after bumping the whisper.cpp submodule)
- RPATH is `$ORIGIN/../lib` so `dist/bin/capsper` finds `dist/lib/*.so` at runtime

Static linking is intentionally avoided — Zig's bundled libc++ conflicts with whisper.cpp's libstdc++ dependency.

## Key Technical Details

- **30-second padding**: whisper.cpp's mel computation requires 480000 samples (30s). Short audio must be zero-padded or the decoder emits immediate EOT.
- **Split prompt decode**: `whisper_get_logits_from_state()` reads from offset 0, but batch decode only populates logits for the last token. Prompt tokens are decoded in two calls: batch first N-1, then the last token alone.
- **AlignAtt always `is_last=true`**: The frame_threshold=25 is too conservative for short streaming buffers. Server-side word stability checking handles hallucination filtering instead.
- **Word-level delta tracking**: Stability is checked at word granularity (not byte), using case-insensitive comparison with trailing punctuation stripped. This handles Whisper changing "so" to "so," between cycles.
- **Sliding window**: Audio buffer capped at 15s (`max_buffer_bytes=480000`). When trimmed, prev_text offset scanning (up to 6 words) realigns the emitted word count.
- **PipeWire FFI must go through C helpers**: Passing `spa_pod**` params through Zig FFI breaks SPA format negotiation (ports get generic names like `input_1`, auto-connect fails, resampling doesn't happen). All PipeWire calls involving SPA pods or variadic macros must be in `src/pw_helpers.c`, not called directly from Zig.

## Workflow

**Always run tests before fixing bugs.** Reproduce the issue first with a test, verify the fix with the same test. Use `./run.ts slow-test compare` to get a baseline before and after changes — it gives concrete word coverage numbers to measure improvement.

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- whisper.cpp is a git submodule pinned to commit `0a4d85cf`
- Model: `ggml-large-v3-turbo-q5_0.bin` (573 MB, q5_0 quantization)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default server port: 43007
- User is on X11 (not Wayland)
