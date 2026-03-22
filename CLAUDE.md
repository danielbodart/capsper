# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Zig and Bun are installed automatically via `bootstrap.sh` + mise. Requires onnxruntime (pre-built in `dist/lib/`).

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

# Regression test groups (requires built binary)
./run.ts short-test                    # 4 short files (<15s) via fast TCP
./run.ts medium-test                   # 2 medium files (15-40s) via fast TCP
./run.ts long-test                     # 3 long files (>60s) via fast TCP

# All integration tests (all groups + stability + pw plumbing)
./run.ts slow-test
```

## Architecture

Push-to-talk voice dictation for Linux. Self-contained binary: grabs keyboards via evdev, intercepts CapsLock as trigger, captures audio via PipeWire, transcribes with Nemotron RNNT (via onnxruntime), injects text as keystrokes via uinput. No external tools needed (no xdotool, ydotool, keyd, xinput). Works on both X11 and Wayland.

> **History:** Capsper originally used whisper.cpp for ASR with Silero/TEN-VAD for voice activity detection. It now uses NVIDIA's Nemotron Speech 600M model (FastConformer RNNT) which is incremental and doesn't need a separate VAD — PTT (push-to-talk) is the sole gate. The name "Capsper" is a nod to Casper the friendly ghost — ghostwriting via CapsLock.

### Zig Binary (`src/`)

Single binary handles everything: keyboard grab, audio capture, transcription, text injection.

- **`main.zig`** — Entry point. Loads Nemotron ONNX model (encoder + decoder + filterbank + tokens), warmup, wires input handler to server.
- **`server.zig`** — PTT-gated streaming loop. Audio chunks go directly to the pipeline for incremental processing. No VAD — PTT press/release drives segmentation. Supports `TypeCallback` for uinput text injection.
- **`nemotron_pipeline.zig`** — Cache-aware FastConformer encoder + RNNT greedy decoder using onnxruntime directly. Receives f32 audio samples incrementally, computes mel features, runs streaming encoder in 560ms chunks, decodes tokens via RNNT greedy search.
- **`input.zig`** — evdev/uinput input handling. Grabs physical keyboards, forwards all keys through virtual uinput keyboard, intercepts trigger key for push-to-talk, injects transcribed text as keystrokes. Includes hotplug (inotify), panic sequence (Enter+Backspace+Escape = ungrab), EVIOCGKEY polling safety net (catches lost key release events every 200ms), and typing cancel (interrupts text injection on PTT release).
- **`utils.zig`** — Pure utility functions (no C deps): PCM-to-float conversion, buffer trimming, WAV parsing/writing, per-channel RMS analysis, text preview. Independently unit-tested.
- **`audio_capture.zig`** — PipeWire audio capture via `pw_thread_loop` + `pw_stream`. Supports software gain via `setGain()`.
- **`pw_detect.zig`** — Interactive PipeWire setup wizard (`--pw-detect`). Enumerates devices, lets user pick, records silence/speech, detects best channel, calibrates auto-gain — all in one flow. Outputs `CHANNEL=`/`GAIN=` to stdout for `install.sh`.
- **`auto_gain.zig`** — Pure-math auto-gain controller. Measures speech RMS and computes PipeWire software gain to reach target level. Capped at 10x (PipeWire ceiling). Used at runtime by `server.zig` and for calibration by `pw_detect.zig`.
- **`nemo_mel.zig`** / **`nemo_mel_state.zig`** — NeMo-compatible mel spectrogram computation (128 bands, pre-emphasis, dither, Slaney normalization). Incremental — only computes FFT for new audio frames.
- **`tokenizer.zig`** — SentencePiece detokenization for Nemotron. Handles ▁ (U+2581) word boundary tokens → spaces.
- **`context_graph.zig`** — Aho-Corasick trie for drop-term suppression (filler phrases like "you know", "Thank you"). Biases RNNT logits during decode.
- **`ort_c.zig`** — Thin Zig FFI wrapper for onnxruntime C API.
- **`pipewire_c.zig`** — C import bridge for PipeWire.
- **`pw_helpers.c`** — C helpers for PipeWire SPA pod building, `pw_stream_connect`, `pw_set_stream_gain`, and PipeWire source enumeration (variadic C calls and SPA macros that Zig can't handle).

### Scripts & Task Runner

- **`run.ts`** — Bun task runner (bootstrapped via `bootstrap.sh` + mise). Commands: `dev` (default), `build`, `clean`, `setup`, `test`, `slow-test`, `dist`, `ci`.
- **`install.sh`** — Self-contained bash installer. Ships in dist tarball. Subcommands: `install` (default), `pw-detect`. Auto-detects dev mode (git checkout via `../.git`) vs user install (`~/.local/share/capsper/`). Downloads Nemotron model from HuggingFace, auto-detects GPU/CPU for FP16 vs INT8 variant.

### Build System & `dist/` Layout

Pre-built onnxruntime shared libraries are committed in `dist/lib/` via Git LFS. The Zig build links against these directly.

```
dist/
├── bin/capsper              (built by zig — gitignored)
├── lib/                     (pre-built .so files — committed via LFS)
│   ├── libonnxruntime.so
│   ├── libonnxruntime_providers_cuda.so
│   └── libonnxruntime_providers_shared.so
├── include/onnxruntime/     (ORT C API headers)
├── models/nemotron/         (downloaded at install time from HuggingFace)
│   ├── encoder_model.onnx + .onnx.data
│   ├── decoder_model.onnx + .onnx.data
│   ├── filterbank.bin
│   ├── tokens.txt
│   └── config.json
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

**Test changes incrementally.** When experimenting with changes that affect transcription quality, run tests in order: short → medium → long. Only proceed to the next level if scores improve. Get baseline by reverting if needed.

## Rules

**Never change test thresholds without human approval.** Regression test thresholds (coverage, WER, gap, repetition limits) in `.test.json` files are carefully tuned. If a code change causes tests to fail, fix the code — don't relax the thresholds. If thresholds genuinely need updating, present the before/after results and get explicit human sign-off.

**Do not attribute test result differences to CUDA non-determinism.** When results differ between test modes or runs, the cause is almost always a real discrepancy in the test methodology or a real code bug — not GPU randomness. Investigate the actual root cause instead of dismissing differences as non-determinism.

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- Model: Nemotron Speech 600M ONNX from `danielbodart/nemotron-speech-600m-onnx` on HuggingFace (FP16 for GPU, INT8 for CPU)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default server port: 43007
