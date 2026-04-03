# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Zig and Bun are installed automatically via `bootstrap.sh` + mise.

```bash
# Default: build + unit tests + short regressions + platform plumbing
./run.ts

# Build only (no tests)
./run.ts build

# Clean build artifacts
./run.ts clean

# Run directly (local push-to-talk via CapsLock)
# Linux:
./dist/linux/bin/capsper --trigger capslock --audio-target my-mic --audio-channel FL --drop-terms drop-terms.txt
# macOS:
./dist/macos/bin/capsper --trigger capslock --drop-terms drop-terms.txt

# Also enable TCP server for remote transcription
./dist/linux/bin/capsper --trigger capslock --audio-target my-mic --port 43007 --drop-terms drop-terms.txt

# TCP-only mode (for testing)
./dist/linux/bin/capsper --port 0 --drop-terms drop-terms.txt

# First-time setup (builds, configures permissions, installs service)
./run.ts setup
```

### Build Variants

The build produces separate binaries per platform via `-Dbackend=`:

| Binary | Platform | Backend | Build Option |
|--------|----------|---------|-------------|
| `capsper` | macOS | CoreML (ANE + CPU) | `-Dbackend=coreml` (default on macOS) |
| `capsper-cuda` | Linux | ORT + CUDA | `-Dbackend=ort_cuda` (default on Linux) |
| `capsper-cpu` | Linux | ORT CPU only | `-Dbackend=ort_cpu` |

On macOS, `./run.ts build` produces one binary. On Linux, it builds both `capsper-cuda` and `capsper-cpu`, plus a `bin/capsper` launcher script that detects GPU and exec's the right one.

### Testing

```bash
# Unit + property tests (fast, no GPU required)
./run.ts test

# Regression test groups (requires built binary)
./run.ts short-test                    # 4 short files (<15s) via fast TCP
./run.ts medium-test                   # 2 medium files (15-40s) via fast TCP
./run.ts long-test                     # 3 long files (>60s) via fast TCP

# All integration tests (all groups + stability + platform plumbing)
./run.ts slow-test
```

## Architecture

Push-to-talk voice dictation for Linux and macOS. Self-contained binary per platform. Supports multiple concurrent transcriptions — `--port` starts a TCP server accepting multiple clients simultaneously, each getting an independent pipeline while sharing the single loaded model. `--audio-target` enables local audio capture (always-live without `--trigger`, PTT-gated with `--trigger`). Both can run simultaneously. On Linux: grabs keyboards via evdev, intercepts CapsLock, captures audio via PipeWire, transcribes with Nemotron RNNT (via onnxruntime), injects text via uinput. On macOS: CGEventTap input, CoreAudio capture, CoreML inference (93% ANE), CGEventPost injection.

> **History:** Capsper originally used whisper.cpp for ASR with Silero/TEN-VAD for voice activity detection. It now uses NVIDIA's Nemotron Speech 600M model (FastConformer RNNT) which is incremental and doesn't need a separate VAD — PTT (push-to-talk) is the sole gate. The name "Capsper" is a nod to Casper the friendly ghost — ghostwriting via CapsLock.

### Source Layout

```
src/
  main.zig                         — Entry point, CLI, model loading

  shared/                          — Platform-agnostic, backend-agnostic
    server.zig                       PTT-gated streaming loop
    utils.zig                        Pure utility functions
    auto_gain.zig                    Auto-gain controller
    recorder.zig                     WAV recording
    asr_types.zig                    Shared ASR types
    nemo_mel.zig                     Mel spectrogram (FFT, filterbank)
    nemo_mel_state.zig               Incremental mel state
    tokenizer.zig                    SentencePiece detokenization
    context_graph.zig                Aho-Corasick drop-term trie
    prop_tests.zig                   Property-based tests

  backend/
    pipeline.zig                   — Comptime switch → concrete Pipeline type
    init.zig                       — Comptime switch → backend-specific init
    ort/                           — ONNX Runtime (Linux CUDA + CPU)
      pipeline.zig                   Nemotron RNNT streaming pipeline
      ort_c.zig                      ORT C API bindings
      init.zig                       ORT model loading, CUDA EP setup
    coreml/                        — CoreML (macOS)
      pipeline.zig                   CoreML streaming pipeline
      helpers.m                      Obj-C bridge (model load, predict, cache)
      init.zig                       CoreML model loading

  platform/
    input.zig                      — Comptime switch → platform input
    audio.zig                      — Comptime switch → platform audio capture
    detect.zig                     — Comptime switch → platform audio detection
    linux/
      input.zig                      evdev/uinput keyboard handling
      audio.zig                      PipeWire audio capture
      detect.zig                     PipeWire device detection
      pw_helpers.c                   PipeWire C helpers (SPA macros)
      pipewire_c.zig                 PipeWire C import bridge
    macos/
      input.zig                      CGEventTap/CGEventPost keyboard
      audio.zig                      CoreAudio AUHAL capture
      detect.zig                     macOS audio device enumeration
      input_helpers.c                CGEvent C helpers
      mic_permission.m               AVCaptureDevice permission check
```

### Scripts & Task Runner

- **`run.ts`** — Bun task runner (bootstrapped via `bootstrap.sh` + mise). Commands: `dev` (default), `build`, `clean`, `setup`, `test`, `slow-test`, `dist`, `ci`. On Linux, builds both CUDA and CPU variants.
- **`install.sh`** — Self-contained bash installer. Ships in dist tarball. On macOS: downloads CoreML models from HuggingFace. On Linux: downloads ONNX models (int8-static for GPU, int8-dynamic for CPU).

### Build System & `dist/` Layout

Platform-specific files are separated into `dist/linux/` and `dist/macos/`, mirroring the `src/platform/` pattern. Shared scripts live in `dist/shared/`. Pre-built onnxruntime shared libraries are committed in `dist/linux/lib/` via Git LFS. macOS uses system CoreML framework.

```
dist/
├── linux/
│   ├── bin/                     (build output: capsper-cuda, capsper-cpu, capsper symlink)
│   ├── lib/                     (pre-built ORT .so files via LFS)
│   ├── include/onnxruntime/     (ORT C API headers — build-time only)
│   ├── install.sh               (Linux installer)
│   ├── capsper-update.sh        (two-phase: stage only, applied on restart)
│   ├── capsper-apply-update.sh  (ExecStartPre: applies staged update)
│   └── capsper-rollback.sh      (OnFailure: auto-rollback)
├── macos/
│   ├── bin/                     (build output: capsper)
│   ├── install.sh               (macOS installer — no auto-update)
│   └── capsper-update.sh        (manual: download + immediate swap)
└── shared/
    └── install-common.sh        (shared helpers, model download, install_files)
```

## Deployment

To update the running capsper service after CI passes:

```bash
# Both platforms: run the update script
~/.local/share/capsper/capsper-update.sh    # downloads from GitHub Releases, verifies SHA256

# Linux: stages update, applied on next restart via ExecStartPre
systemctl --user restart capsper

# macOS: downloads, swaps, and restarts in one step (no auto-update timer)
```

Do NOT manually download CI artifacts or stage releases by hand — the update script handles everything.

## Workflow

**Always run tests before fixing bugs.** Reproduce the issue first with a test, verify the fix with the same test.

**Don't run redundant test commands.** `./run.ts` (no args) already does build + unit tests + property tests + short regressions + platform plumbing — that's the standard verify step. Do NOT run `./run.ts build`, `./run.ts test`, and `./run.ts short-test` separately — that just repeats work. Only run `./run.ts slow-test` when you specifically need medium/long regression results (e.g. measuring WER improvement on long files).

**Test changes incrementally.** When experimenting with changes that affect transcription quality, run tests in order: short → medium → long. Only proceed to the next level if scores improve. Get baseline by reverting if needed.

## Rules

**Never change test thresholds without human approval.** Regression test thresholds (coverage, WER, gap, repetition limits) in `.test.json` files are carefully tuned. If a code change causes tests to fail, fix the code — don't relax the thresholds. If thresholds genuinely need updating, present the before/after results and get explicit human sign-off.

**Do not attribute test result differences to CUDA non-determinism.** When results differ between test modes or runs, the cause is almost always a real discrepancy in the test methodology or a real code bug — not GPU randomness. Investigate the actual root cause instead of dismissing differences as non-determinism.

## Conventions

- Zig 0.15 API: `b.createModule(...)` for executables, `file.reader(&buf)` takes a buffer arg, use `readToEndAlloc` instead of `readBytesNoEof`
- Build: `-Dbackend=coreml|ort_cuda|ort_cpu` selects ASR backend at compile time
- Models: CoreML from `danielbodart/nemotron-speech-600m-coreml`, ONNX from `danielbodart/nemotron-speech-600m-onnx` on HuggingFace
- Conversion scripts: [nemotron-speech-600m-coreml](https://github.com/danielbodart/nemotron-speech-600m-coreml) (CoreML), [nemotron-speech-600m-onnx](https://github.com/danielbodart/nemotron-speech-600m-onnx) (ONNX)
- Audio format: 16kHz mono S16_LE PCM (32000 bytes/sec)
- Default TCP port: 43007 (only active when `--port` is specified)
- CLI flags: `--audio-target` implies local capture, `--trigger` adds PTT, `--port` enables TCP server. `--audio-channel`, `--audio-gain`, `--audio-detect` (cross-platform names; `--pw-*` aliases kept for backwards compat). `--stream FILE` (streaming) and `--transcribe FILE` (batch) for file transcription. Unknown flags warn instead of failing.
- Service management: `systemctl --user` on Linux, `launchctl bootstrap/bootout gui/$(id -u)` on macOS
- Service files: `~/.config/systemd/user/capsper.service` (Linux), `~/Library/LaunchAgents/io.github.danielbodart.capsper.plist` (macOS)
- Permissions: `input` group + udev rule on Linux; Accessibility + Microphone TCC on macOS
